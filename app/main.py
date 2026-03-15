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




@app.get("/price/{symbol}")
def get_symbol_price(symbol: str, db: Session = Depends(get_db)):
    """
    Get live price for a single symbol — bypasses cache for freshness.
    Used by AddStockView / AddCryptoBuyView when first selecting an asset.
    """
    sym = symbol.upper()
    fx_to_usd = fetch_fx_rates()

    asset = db.query(models.Asset).filter(models.Asset.symbol == sym).first()
    if not asset:
        raise HTTPException(status_code=404, detail=f"Asset {sym} not found")

    cls = asset.asset_class.lower()

    if cls == "fiat" or sym in FIAT_SYMBOLS:
        rate = fx_to_usd.get(sym, 1.0)
        price_usd = (1.0 / rate) if rate > 0 else 1.0
    elif sym in STABLECOIN_SYMBOLS:
        price_usd = 1.0
    elif cls == "crypto":
        # Force fresh Binance fetch (invalidate cache for this symbol)
        binance_prices = fetch_binance_all_prices()
        pair  = BINANCE_PAIR_OVERRIDES.get(sym, f"{sym}USDT")
        price_usd = float(binance_prices.get(pair, 0.0))
    elif cls in ("stock", "etf"):
        # Force fresh FMP fetch — bypass 5min cache for single symbol lookup
        try:
            url = f"https://financialmodelingprep.com/api/v3/quote-short/{sym}?apikey={FMP_API_KEY}"
            with httpx.Client(timeout=8.0) as c:
                r = c.get(url); r.raise_for_status()
                data = r.json()
            if data and isinstance(data, list):
                price_usd = float(data[0].get("price", 0.0))
            else:
                price_usd = 0.0
        except Exception as e:
            logger.warning(f"FMP single price failed for {sym}: {e}")
            price_usd = 0.0
    else:
        price_usd = 0.0

    return {
        "symbol":    sym,
        "price_usd": price_usd,
        "price_live": price_usd > 0,
        "fx_to_usd": fx_to_usd,
    }


def _build_recent_activity(events, db, fx_to_usd: dict, base_currency: str) -> list:
    """Build recent activity list with FX-converted amounts and account names."""
    assets_map   = {a.id: a for a in db.query(models.Asset).all()}
    accounts_map = {a.id: a for a in db.query(models.Account).all()}
    base_upper   = base_currency.upper()
    result = []

    for e in events:
        legs = db.query(models.TransactionLeg).filter(models.TransactionLeg.event_id == e.id).all()

        # Compute FX-converted amount
        display_amount = 0.0
        account_name   = None

        for leg in legs:
            if leg.quantity <= 0:
                continue  # only look at inflows for display
            asset   = assets_map.get(leg.asset_id)
            account = accounts_map.get(leg.account_id)
            if account:
                account_name = account.name

            if not asset:
                display_amount += leg.quantity
                continue

            sym = asset.symbol.upper()
            cls = asset.asset_class.lower()

            if cls == "fiat" or sym in FIAT_SYMBOLS:
                asset_rate = fx_to_usd.get(sym, 1.0)
                base_rate  = fx_to_usd.get(base_upper, 1.0)
                if asset_rate > 0 and base_rate > 0:
                    display_amount += (leg.quantity / asset_rate) * base_rate
                else:
                    display_amount += leg.quantity
            elif sym in STABLECOIN_SYMBOLS:
                base_rate = fx_to_usd.get(base_upper, 1.0)
                display_amount += leg.quantity * base_rate
            else:
                price_usd = leg.unit_price or 0.0
                base_rate = fx_to_usd.get(base_upper, 1.0)
                display_amount += leg.quantity * price_usd * base_rate

        # For expenses, use outflow legs
        if e.event_type.lower() == "expense" and display_amount == 0:
            for leg in legs:
                if leg.quantity >= 0:
                    continue
                asset = assets_map.get(leg.asset_id)
                account = accounts_map.get(leg.account_id)
                if account:
                    account_name = account.name
                if not asset:
                    display_amount += abs(leg.quantity)
                    continue
                sym = asset.symbol.upper()
                cls = asset.asset_class.lower()
                if cls == "fiat" or sym in FIAT_SYMBOLS:
                    asset_rate = fx_to_usd.get(sym, 1.0)
                    base_rate  = fx_to_usd.get(base_upper, 1.0)
                    if asset_rate > 0 and base_rate > 0:
                        display_amount += (abs(leg.quantity) / asset_rate) * base_rate
                    else:
                        display_amount += abs(leg.quantity)

        result.append({
            "id":           e.id,
            "event_type":   e.event_type,
            "category":     e.category,
            "description":  e.description,
            "date":         e.date,
            "note":         e.note,
            "amount":       round(display_amount, 2),
            "account_name": account_name,
        })

    return result

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
        live_price = price_map.get(sym, 0.0)

        # ✅ Fall back to avg_cost when live price unavailable (after-hours, API down)
        # avg_cost is stored in the asset's quote_currency (USD for stocks/crypto)
        price_usd = live_price if live_price > 0 else holding.avg_cost

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
            "price_live":    live_price > 0,   # false = using avg_cost fallback
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
        "recent_activity": _build_recent_activity(recent_events, db, fx_to_usd, base_upper),
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
@app.get("/transaction-events")
def list_transaction_events(base_currency: str = "USD", db: Session = Depends(get_db)):
    """
    Returns transactions with amounts converted to base_currency.
    e.g. €1,000 income displayed in USD = ~$1,145 (not $1,000).
    """
    try:
        fx_to_usd = fetch_fx_rates()
    except Exception:
        fx_to_usd = _FALLBACK_FX

    events  = db.query(models.TransactionEvent).order_by(models.TransactionEvent.date.desc()).all()
    assets  = {a.id: a for a in db.query(models.Asset).all()}
    base_upper = base_currency.upper()

    items = []
    for e in events:
        legs = db.query(models.TransactionLeg).filter(models.TransactionLeg.event_id == e.id).all()

        # Convert each leg's quantity to base currency value
        def leg_value_in_base(leg) -> float:
            asset = assets.get(leg.asset_id)
            if not asset:
                return abs(leg.quantity)   # fallback: raw quantity
            sym = asset.symbol.upper()
            cls = asset.asset_class.lower()

            if cls == "fiat" or sym in FIAT_SYMBOLS:
                # Fiat: convert via FX
                asset_rate = fx_to_usd.get(sym, 1.0)
                base_rate  = fx_to_usd.get(base_upper, 1.0)
                if asset_rate > 0 and base_rate > 0:
                    value_usd = abs(leg.quantity) / asset_rate
                    return value_usd * base_rate
                return abs(leg.quantity)
            elif sym in STABLECOIN_SYMBOLS or cls == "stablecoin":
                # Stablecoin: always $1 → convert to base
                base_rate = fx_to_usd.get(base_upper, 1.0)
                return abs(leg.quantity) * base_rate if base_rate > 0 else abs(leg.quantity)
            else:
                # Crypto/stock: use unit_price if available, else price from map
                price_usd = leg.unit_price if leg.unit_price else 0.0
                base_rate = fx_to_usd.get(base_upper, 1.0)
                value_usd = abs(leg.quantity) * price_usd
                return value_usd * base_rate if base_rate > 0 else value_usd

        # Separate inflow and outflow legs
        inflow_legs  = [l for l in legs if l.quantity > 0]
        outflow_legs = [l for l in legs if l.quantity < 0]

        if e.event_type.lower() in ("income", "expense", "transfer"):
            # For fiat transactions, use the fiat leg amount converted to base
            display_amount = sum(leg_value_in_base(l) for l in inflow_legs) if inflow_legs else sum(leg_value_in_base(l) for l in outflow_legs)
        else:
            # Trade: show the fiat cost (outflow) converted to base
            display_amount = sum(leg_value_in_base(l) for l in outflow_legs) if outflow_legs else sum(leg_value_in_base(l) for l in inflow_legs)

        items.append({
            "id":           e.id,
            "event_type":   e.event_type,
            "category":     e.category,
            "description":  e.description,
            "date":         e.date,
            "note":         e.note,
            "source":       e.source,
            "external_id":  e.external_id,
            "amount":       round(display_amount, 2),
            "base_currency": base_upper,
        })
    return {"items": items}


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



# ─────────────────────────────────────────────────────────────────────────────
# /assets/search  — live search across Binance (crypto) + FMP (stocks)
# Auto-creates the asset in DB if not already there so it's available for trades
# ─────────────────────────────────────────────────────────────────────────────
@app.get("/assets/search")
def search_assets(q: str, db: Session = Depends(get_db)):
    q = q.strip().upper()
    if not q or len(q) < 1:
        return {"items": []}

    results = []

    # ── 1. Check existing DB assets first ──────────────────────────────────
    db_assets = db.query(models.Asset).filter(
        (models.Asset.symbol.ilike(f"%{q}%")) |
        (models.Asset.name.ilike(f"%{q}%"))
    ).limit(10).all()

    seen_symbols = set()
    for a in db_assets:
        seen_symbols.add(a.symbol.upper())
        results.append({
            "id": a.id, "symbol": a.symbol, "name": a.name,
            "asset_class": a.asset_class, "quote_currency": a.quote_currency,
            "source": "db",
        })

    # ── 2. Search Binance for crypto ────────────────────────────────────────
    try:
        binance_prices = fetch_binance_all_prices()
        crypto_matches = []
        for pair, price in binance_prices.items():
            if not pair.endswith("USDT"):
                continue
            sym = pair.replace("USDT", "")
            if q in sym and sym not in seen_symbols and sym not in FIAT_SYMBOLS and sym not in STABLECOIN_SYMBOLS:
                crypto_matches.append((sym, price))

        crypto_matches.sort(key=lambda x: (len(x[0]), x[0]))

        for sym, price in crypto_matches[:8]:
            if sym in seen_symbols:
                continue
            seen_symbols.add(sym)

            existing = db.query(models.Asset).filter(models.Asset.symbol == sym).first()
            if not existing:
                new_asset = models.Asset(
                    id=str(uuid4()), symbol=sym, name=sym,
                    asset_class="crypto", quote_currency="USD",
                )
                db.add(new_asset)
                db.flush()
                asset_id = new_asset.id
            else:
                asset_id = existing.id

            results.append({
                "id": asset_id, "symbol": sym, "name": sym,
                "asset_class": "crypto", "quote_currency": "USD",
                "price_usd": price, "source": "binance",
            })

        db.commit()

    except Exception as e:
        logger.warning(f"Binance search failed: {e}")

    # ── 3. Search FMP for stocks ─────────────────────────────────────────────
    try:
        url = f"https://financialmodelingprep.com/api/v3/search?query={q}&limit=10&apikey={FMP_API_KEY}"
        with httpx.Client(timeout=8.0) as c:
            r = c.get(url)
            r.raise_for_status()
            fmp_results = r.json()

        for item in fmp_results:
            sym        = item.get("symbol", "").upper()
            name       = item.get("name", sym)
            exchange   = item.get("exchangeShortName", "")
            stock_type = item.get("type", "stock").lower()

            if exchange not in ("NYSE", "NASDAQ", "AMEX", "ETF", "TSX"):
                continue
            if sym in seen_symbols or sym in FIAT_SYMBOLS:
                continue
            seen_symbols.add(sym)

            asset_class = "etf" if stock_type == "etf" else "stock"

            existing = db.query(models.Asset).filter(models.Asset.symbol == sym).first()
            if not existing:
                new_asset = models.Asset(
                    id=str(uuid4()), symbol=sym, name=name,
                    asset_class=asset_class, quote_currency="USD",
                )
                db.add(new_asset)
                db.flush()
                asset_id = new_asset.id
            else:
                asset_id = existing.id

            results.append({
                "id": asset_id, "symbol": sym, "name": name,
                "asset_class": asset_class, "quote_currency": "USD",
                "exchange": exchange, "source": "fmp",
            })

        db.commit()

    except Exception as e:
        logger.warning(f"FMP search failed: {e}")

    return {"items": results[:20]}

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
