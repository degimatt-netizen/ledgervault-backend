from uuid import uuid4
import time
import os
import logging

import httpx
from fastapi import FastAPI, Depends, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy.orm import Session

from app.db import engine, SessionLocal, Base
from app import models
from app.schemas import (
    AccountList, AccountOut, AccountCreate, AccountUpdate,
    AssetList, AssetOut, AssetCreate,
    HoldingList,
    TransactionEventList, TransactionEventOut, TransactionEventCreate,
    TransactionLegList,
)

app = FastAPI(title="LedgerVault API", version="4.1.0")
models.Base.metadata.create_all(bind=engine)
logger = logging.getLogger("ledgervault")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


# ─────────────────────────────────────────────────────────────────────────────
# Constants
# ─────────────────────────────────────────────────────────────────────────────
FIAT_SYMBOLS = {
    "USD","EUR","GBP","CHF","CAD","AUD","JPY","PLN","SEK","NOK","CZK",
    "HKD","SGD","NZD","DKK","HUF","RON","BGN","TRY","INR","BRL","MXN",
    "ZAR","KRW","TWD","CNY","SAR","AED","QAR","KWD",
}

STABLECOIN_SYMBOLS = {"USDT","USDC","DAI","BUSD","TUSD","USDP","FRAX","GUSD","PYUSD"}

BINANCE_PAIR_OVERRIDES = {
    "BTC":"BTCUSDT","ETH":"ETHUSDT","SOL":"SOLUSDT","BNB":"BNBUSDT",
    "XRP":"XRPUSDT","ADA":"ADAUSDT","DOGE":"DOGEUSDT","DOT":"DOTUSDT",
    "MATIC":"MATICUSDT","LINK":"LINKUSDT","AVAX":"AVAXUSDT","UNI":"UNIUSDT",
    "ATOM":"ATOMUSDT","LTC":"LTCUSDT","ETC":"ETCUSDT","XLM":"XLMUSDT",
    "ALGO":"ALGOUSDT","FIL":"FILUSDT","TRX":"TRXUSDT","NEAR":"NEARUSDT",
    "OP":"OPUSDT","ARB":"ARBUSDT","SUI":"SUIUSDT","INJ":"INJUSDT",
    "PEPE":"PEPEUSDT","WIF":"WIFUSDT","FTM":"FTMUSDT","SAND":"SANDUSDT",
    "MANA":"MANAUSDT","AAVE":"AAVEUSDT","GRT":"GRTUSDT",
}

# FMP API key for live stock prices
FMP_API_KEY = "hmgg5wge45iAO50bYUIYTsGJYEdTw9Wc"

# ─────────────────────────────────────────────────────────────────────────────
# Cache
# ─────────────────────────────────────────────────────────────────────────────
_cache: dict = {}
FX_TTL     = int(os.getenv("FX_CACHE_TTL_SECONDS",    "900"))
CRYPTO_TTL = int(os.getenv("CRYPTO_CACHE_TTL_SECONDS", "60"))
STOCK_TTL  = int(os.getenv("STOCK_CACHE_TTL_SECONDS",  "300"))


def _cached(key: str, ttl: int):
    e = _cache.get(key)
    if e and (time.time() - e["ts"]) < ttl:
        return e["data"]
    return None


def _store(key: str, data):
    _cache[key] = {"ts": time.time(), "data": data}
    return data


# ─────────────────────────────────────────────────────────────────────────────
# Live FX  (open.er-api.com — free, no key needed)
# ─────────────────────────────────────────────────────────────────────────────
FX_URL = os.getenv("FX_PROVIDER_URL", "https://open.er-api.com/v6/latest/USD")
_FALLBACK_FX = {"USD":1.0,"EUR":0.92,"GBP":0.79,"CHF":0.90,"CAD":1.37,"AUD":1.52,"JPY":149.0}


def fetch_fx_rates() -> dict:
    cached = _cached("fx", FX_TTL)
    if cached:
        return cached
    try:
        with httpx.Client(timeout=8.0) as c:
            r = c.get(FX_URL)
            r.raise_for_status()
            rates = r.json().get("rates", {})
        fx = {"USD": 1.0}
        for k, v in rates.items():
            try:
                fx[str(k).upper()] = float(v)
            except:
                pass
        logger.info(f"FX refreshed: {len(fx)} currencies")
        return _store("fx", fx)
    except Exception as e:
        logger.warning(f"FX fetch failed: {e}")
        return _FALLBACK_FX


# ─────────────────────────────────────────────────────────────────────────────
# Live Crypto  (Binance public API — free, no key, very reliable)
# ─────────────────────────────────────────────────────────────────────────────
BINANCE_URL = "https://api.binance.com/api/v3/ticker/price"


def fetch_binance_all_prices() -> dict:
    cached = _cached("binance_all", CRYPTO_TTL)
    if cached:
        return cached
    try:
        with httpx.Client(timeout=10.0) as c:
            r = c.get(BINANCE_URL)
            r.raise_for_status()
            data = r.json()
        prices = {item["symbol"]: float(item["price"]) for item in data}
        logger.info(f"Binance: fetched {len(prices)} pairs")
        return _store("binance_all", prices)
    except Exception as e:
        logger.warning(f"Binance fetch failed: {e}")
        return {}


def fetch_crypto_prices(symbols: set) -> dict:
    result = {s: 1.0 for s in symbols if s.upper() in STABLECOIN_SYMBOLS}
    needed = {s for s in symbols if s.upper() not in STABLECOIN_SYMBOLS}
    if not needed:
        return result
    binance_prices = fetch_binance_all_prices()
    for sym in needed:
        sym_upper = sym.upper()
        pair  = BINANCE_PAIR_OVERRIDES.get(sym_upper, f"{sym_upper}USDT")
        price = binance_prices.get(pair) or binance_prices.get(f"{sym_upper}BUSD")
        if price and price > 0:
            result[sym_upper] = price
            logger.info(f"Crypto: {sym_upper} = ${price}")
        else:
            logger.warning(f"No Binance price for {sym_upper}")
    return result


# ─────────────────────────────────────────────────────────────────────────────
# Live Stocks  (Financial Modeling Prep — free tier)
# ─────────────────────────────────────────────────────────────────────────────
def fetch_stock_prices(symbols: set) -> dict:
    if not symbols:
        return {}
    cached_key = "stocks_" + "_".join(sorted(symbols))
    cached = _cached(cached_key, STOCK_TTL)
    if cached:
        return cached
    try:
        sym_str = ",".join(sorted(symbols))
        url = f"https://financialmodelingprep.com/api/v3/quote-short/{sym_str}?apikey={FMP_API_KEY}"
        with httpx.Client(timeout=10.0) as c:
            r = c.get(url)
            r.raise_for_status()
            data = r.json()
        prices = {}
        for item in data:
            sym   = item.get("symbol", "").upper()
            price = item.get("price")
            if sym and price and float(price) > 0:
                prices[sym] = float(price)
        logger.info(f"FMP stock prices: {prices}")
        return _store(cached_key, prices)
    except Exception as e:
        logger.warning(f"FMP fetch failed: {e}")
        return {}


# ─────────────────────────────────────────────────────────────────────────────
# Master price resolver
# ─────────────────────────────────────────────────────────────────────────────
def get_prices_usd(assets: list, fx_to_usd: dict) -> dict:
    prices = {}
    crypto_syms = set()
    stock_syms  = set()

    for asset in assets:
        sym = asset.symbol.upper()
        cls = asset.asset_class.lower()

        if sym in FIAT_SYMBOLS or cls == "fiat":
            rate = fx_to_usd.get(sym, 1.0)
            prices[sym] = (1.0 / rate) if rate > 0 else 1.0
        elif sym in STABLECOIN_SYMBOLS:
            prices[sym] = 1.0
        elif cls == "crypto":
            crypto_syms.add(sym)
        elif cls in ("stock", "etf"):
            stock_syms.add(sym)
        else:
            prices[sym] = 0.0

    if crypto_syms:
        prices.update(fetch_crypto_prices(crypto_syms))
    if stock_syms:
        prices.update(fetch_stock_prices(stock_syms))

    return prices


# ─────────────────────────────────────────────────────────────────────────────
# FX conversion helper
# fx_to_usd[X] = units of X per 1 USD  (e.g. EUR=0.873 → 1 USD = 0.873 EUR)
# value_base = value_usd * base_rate
# ─────────────────────────────────────────────────────────────────────────────
def usd_to_base(value_usd: float, base_currency: str, fx_to_usd: dict) -> float:
    rate = fx_to_usd.get(base_currency.upper(), 1.0)
    return value_usd * rate if rate > 0 else value_usd


# ─────────────────────────────────────────────────────────────────────────────
# Endpoints
# ─────────────────────────────────────────────────────────────────────────────
@app.get("/")
def root():
    return {
        "status": "ok",
        "message": "LedgerVault API v4.1 — Binance crypto + FMP stocks + live FX",
        "fmp_key_set": bool(FMP_API_KEY),
    }


@app.post("/reset")
def reset_database():
    Base.metadata.drop_all(bind=engine)
    Base.metadata.create_all(bind=engine)
    return {"status": "ok", "message": "database reset"}


@app.get("/rates")
def get_rates(db: Session = Depends(get_db)):
    fx_to_usd   = fetch_fx_rates()
    all_assets  = db.query(models.Asset).all()
    live_prices = get_prices_usd(all_assets, fx_to_usd)
    return {
        "base_reference": "USD",
        "prices":    live_prices,
        "fx_to_usd": fx_to_usd,
        "fx_source": "live",
    }


@app.get("/valuation")
def valuation(base_currency: str = "EUR", db: Session = Depends(get_db)):
    fx_to_usd = fetch_fx_rates()
    holdings  = db.query(models.Holding).all()
    assets    = {a.id: a for a in db.query(models.Asset).all()}
    accounts  = {a.id: a for a in db.query(models.Account).all()}

    held_assets = list({h.asset_id: assets[h.asset_id] for h in holdings if h.asset_id in assets}.values())
    price_map   = get_prices_usd(held_assets, fx_to_usd)

    portfolio_items  = []
    total_value_base = 0.0
    cash_total = crypto_total = stock_total = 0.0
    base_upper = base_currency.upper()

    for holding in holdings:
        asset   = assets.get(holding.asset_id)
        account = accounts.get(holding.account_id)
        if not asset or not account:
            continue

        sym        = asset.symbol.upper()
        cls        = asset.asset_class.lower()
        price_usd  = price_map.get(sym, 0.0)
        value_usd  = holding.quantity * price_usd
        value_base = usd_to_base(value_usd, base_upper, fx_to_usd)

        portfolio_items.append({
            "holding_id":    holding.id,
            "account_id":    account.id,
            "account_name":  account.name,
            "asset_id":      asset.id,
            "symbol":        asset.symbol,
            "asset_name":    asset.name,
            "asset_class":   asset.asset_class,
            "quantity":      holding.quantity,
            "avg_cost":      holding.avg_cost,
            "price_usd":     round(price_usd, 6),
            "value_in_base": round(value_base, 2),
            "base_currency": base_upper,
        })

        total_value_base += value_base
        if cls == "fiat":
            cash_total   += value_base
        elif cls in ("crypto", "stablecoin"):
            crypto_total += value_base
        elif cls in ("stock", "etf"):
            stock_total  += value_base

    recent_events = (
        db.query(models.TransactionEvent)
        .order_by(models.TransactionEvent.date.desc())
        .limit(10).all()
    )

    return {
        "base_currency":   base_upper,
        "total":           round(total_value_base, 2),
        "cash":            round(cash_total, 2),
        "crypto":          round(crypto_total, 2),
        "stocks":          round(stock_total, 2),
        "portfolio":       portfolio_items,
        "recent_activity": [
            {
                "id":          e.id,
                "event_type":  e.event_type,
                "category":    e.category,
                "description": e.description,
                "date":        e.date,
                "note":        e.note,
            }
            for e in recent_events
        ],
    }


# ── Accounts ──────────────────────────────────────────────────────────────────
@app.get("/accounts", response_model=AccountList)
def list_accounts(db: Session = Depends(get_db)):
    return {"items": db.query(models.Account).all()}


@app.post("/accounts", response_model=AccountOut)
def create_account(payload: AccountCreate, db: Session = Depends(get_db)):
    item = models.Account(
        id=str(uuid4()), name=payload.name,
        account_type=payload.account_type,
        base_currency=payload.base_currency.upper(),
    )
    db.add(item); db.commit(); db.refresh(item)
    return item


@app.put("/accounts/{account_id}", response_model=AccountOut)
def update_account(account_id: str, payload: AccountUpdate, db: Session = Depends(get_db)):
    item = db.query(models.Account).filter(models.Account.id == account_id).first()
    if not item:
        raise HTTPException(404, "Account not found")
    if payload.name is not None:          item.name = payload.name
    if payload.account_type is not None:  item.account_type = payload.account_type
    if payload.base_currency is not None: item.base_currency = payload.base_currency.upper()
    db.commit(); db.refresh(item)
    return item


@app.delete("/accounts/{account_id}")
def delete_account(account_id: str, db: Session = Depends(get_db)):
    item = db.query(models.Account).filter(models.Account.id == account_id).first()
    if not item:
        raise HTTPException(404, "Account not found")
    if (db.query(models.TransactionLeg).filter(models.TransactionLeg.account_id == account_id).first() or
        db.query(models.Holding).filter(models.Holding.account_id == account_id).first()):
        raise HTTPException(400, "Cannot delete account with activity or holdings. Delete related transactions first.")
    db.delete(item); db.commit()
    return {"status": "ok"}


# ── Assets ────────────────────────────────────────────────────────────────────
@app.get("/assets", response_model=AssetList)
def list_assets(db: Session = Depends(get_db)):
    return {"items": db.query(models.Asset).all()}


@app.post("/assets", response_model=AssetOut)
def create_asset(payload: AssetCreate, db: Session = Depends(get_db)):
    existing = db.query(models.Asset).filter(models.Asset.symbol == payload.symbol.upper()).first()
    if existing:
        return existing
    item = models.Asset(
        id=str(uuid4()), symbol=payload.symbol.upper(), name=payload.name,
        asset_class=payload.asset_class, quote_currency=payload.quote_currency.upper(),
    )
    db.add(item); db.commit(); db.refresh(item)
    return item


# ── Holdings ──────────────────────────────────────────────────────────────────
@app.get("/holdings", response_model=HoldingList)
def list_holdings(db: Session = Depends(get_db)):
    return {"items": db.query(models.Holding).all()}


# ── Transactions ──────────────────────────────────────────────────────────────
@app.get("/transaction-events", response_model=TransactionEventList)
def list_transaction_events(db: Session = Depends(get_db)):
    return {"items": db.query(models.TransactionEvent).order_by(models.TransactionEvent.date.desc()).all()}


@app.get("/transaction-legs", response_model=TransactionLegList)
def list_transaction_legs(db: Session = Depends(get_db)):
    return {"items": db.query(models.TransactionLeg).all()}


@app.delete("/transaction-events/{event_id}")
def delete_transaction_event(event_id: str, db: Session = Depends(get_db)):
    try:
        event = db.query(models.TransactionEvent).filter(models.TransactionEvent.id == event_id).first()
        if not event:
            raise HTTPException(404, "Transaction event not found")
        legs = db.query(models.TransactionLeg).filter(models.TransactionLeg.event_id == event_id).all()
        for leg in legs:
            holding = db.query(models.Holding).filter(
                models.Holding.account_id == leg.account_id,
                models.Holding.asset_id   == leg.asset_id,
            ).first()
            if holding:
                new_qty = holding.quantity - leg.quantity
                if new_qty <= 0: db.delete(holding)
                else: holding.quantity = new_qty
            db.delete(leg)
        db.flush(); db.delete(event); db.commit()
        return {"status": "ok"}
    except HTTPException:
        db.rollback(); raise
    except Exception as e:
        db.rollback()
        raise HTTPException(500, f"Delete failed: {e}")


@app.post("/transaction-events", response_model=TransactionEventOut)
def create_transaction_event(payload: TransactionEventCreate, db: Session = Depends(get_db)):
    if not payload.legs:
        raise HTTPException(400, "At least one leg is required")

    event = models.TransactionEvent(
        id=str(uuid4()), event_type=payload.event_type, category=payload.category,
        description=payload.description, date=payload.date, note=payload.note,
        source=payload.source, external_id=payload.external_id,
    )
    db.add(event); db.flush()

    for leg in payload.legs:
        account = db.query(models.Account).filter(models.Account.id == leg.account_id).first()
        if not account:
            raise HTTPException(404, f"Account not found: {leg.account_id}")
        asset = db.query(models.Asset).filter(models.Asset.id == leg.asset_id).first()
        if not asset:
            raise HTTPException(404, f"Asset not found: {leg.asset_id}")

        holding = db.query(models.Holding).filter(
            models.Holding.account_id == leg.account_id,
            models.Holding.asset_id   == leg.asset_id,
        ).first()

        if not holding:
            holding = models.Holding(
                id=str(uuid4()), account_id=leg.account_id,
                asset_id=leg.asset_id, quantity=0.0, avg_cost=0.0,
            )
            db.add(holding); db.flush()

        old_qty = holding.quantity
        new_qty = old_qty + leg.quantity
        if leg.quantity > 0 and leg.unit_price is not None:
            total_cost = old_qty * holding.avg_cost + leg.quantity * leg.unit_price
            if new_qty > 0:
                holding.avg_cost = total_cost / new_qty
        holding.quantity = max(new_qty, 0.0)
        if holding.quantity == 0:
            db.delete(holding)

        db.add(models.TransactionLeg(
            id=str(uuid4()), event_id=event.id,
            account_id=leg.account_id, asset_id=leg.asset_id,
            quantity=leg.quantity, unit_price=leg.unit_price,
            fee_flag="true" if leg.fee_flag else "false",
        ))

    db.commit(); db.refresh(event)
    return event


# ── Seed ──────────────────────────────────────────────────────────────────────
@app.post("/seed")
def seed_data(db: Session = Depends(get_db)):
    seed_assets = [
        # Fiat
        ("EUR","Euro","fiat","EUR"),
        ("USD","US Dollar","fiat","USD"),
        ("GBP","British Pound","fiat","GBP"),
        ("CHF","Swiss Franc","fiat","CHF"),
        ("CAD","Canadian Dollar","fiat","CAD"),
        ("AUD","Australian Dollar","fiat","AUD"),
        ("JPY","Japanese Yen","fiat","JPY"),
        ("PLN","Polish Zloty","fiat","PLN"),
        ("SEK","Swedish Krona","fiat","SEK"),
        ("NOK","Norwegian Krone","fiat","NOK"),
        # Stablecoins
        ("USDT","Tether","crypto","USD"),
        ("USDC","USD Coin","crypto","USD"),
        ("DAI","Dai","crypto","USD"),
        # Crypto
        ("BTC","Bitcoin","crypto","USD"),
        ("ETH","Ethereum","crypto","USD"),
        ("SOL","Solana","crypto","USD"),
        ("BNB","BNB","crypto","USD"),
        ("XRP","XRP","crypto","USD"),
        ("ADA","Cardano","crypto","USD"),
        ("DOGE","Dogecoin","crypto","USD"),
        ("AVAX","Avalanche","crypto","USD"),
        ("DOT","Polkadot","crypto","USD"),
        ("MATIC","Polygon","crypto","USD"),
        ("LINK","Chainlink","crypto","USD"),
        ("LTC","Litecoin","crypto","USD"),
        ("NEAR","NEAR Protocol","crypto","USD"),
        ("OP","Optimism","crypto","USD"),
        ("ARB","Arbitrum","crypto","USD"),
        ("SUI","Sui","crypto","USD"),
        ("PEPE","Pepe","crypto","USD"),
        # Stocks
        ("AAPL","Apple Inc.","stock","USD"),
        ("TSLA","Tesla Inc.","stock","USD"),
        ("MSFT","Microsoft Corp.","stock","USD"),
        ("NVDA","NVIDIA Corp.","stock","USD"),
        ("GOOGL","Alphabet Inc.","stock","USD"),
        ("AMZN","Amazon.com Inc.","stock","USD"),
        ("META","Meta Platforms","stock","USD"),
        ("NFLX","Netflix Inc.","stock","USD"),
        ("AMD","AMD Inc.","stock","USD"),
        ("INTC","Intel Corp.","stock","USD"),
        ("COIN","Coinbase Global","stock","USD"),
        ("PYPL","PayPal Holdings","stock","USD"),
        ("DIS","Walt Disney Co.","stock","USD"),
        ("UBER","Uber Technologies","stock","USD"),
        ("SHOP","Shopify Inc.","stock","USD"),
        ("PLTR","Palantir Technologies","stock","USD"),
        ("SQ","Block Inc.","stock","USD"),
        ("RBLX","Roblox Corp.","stock","USD"),
        ("SPOT","Spotify Technology","stock","USD"),
    ]
    count = 0
    for symbol, name, asset_class, quote_currency in seed_assets:
        if not db.query(models.Asset).filter(models.Asset.symbol == symbol).first():
            db.add(models.Asset(
                id=str(uuid4()), symbol=symbol, name=name,
                asset_class=asset_class, quote_currency=quote_currency,
            ))
            count += 1
    db.commit()
    return {"status": "ok", "added": count}
