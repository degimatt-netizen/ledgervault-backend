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

app = FastAPI(title="LedgerVault API", version="4.0.0")
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
# Known fiat currency symbols – these are priced via FX rates, not price feeds
# ─────────────────────────────────────────────────────────────────────────────
FIAT_SYMBOLS = {
    "USD", "EUR", "GBP", "CHF", "CAD", "AUD", "JPY", "PLN", "SEK", "NOK",
    "CZK", "HKD", "SGD", "NZD", "DKK", "HUF", "RON", "BGN", "TRY", "INR",
    "BRL", "MXN", "ZAR", "KRW", "TWD", "CNY", "SAR", "AED", "QAR", "KWD",
}

# Stablecoins – always $1.00
STABLECOIN_SYMBOLS = {"USDT", "USDC", "DAI", "BUSD", "TUSD", "USDP", "FRAX", "GUSD"}

# CoinGecko ID map for common crypto symbols
COINGECKO_IDS = {
    "BTC": "bitcoin", "ETH": "ethereum", "BNB": "binancecoin",
    "SOL": "solana", "XRP": "ripple", "ADA": "cardano", "DOGE": "dogecoin",
    "DOT": "polkadot", "MATIC": "matic-network", "SHIB": "shiba-inu",
    "LTC": "litecoin", "AVAX": "avalanche-2", "LINK": "chainlink",
    "UNI": "uniswap", "ATOM": "cosmos", "XLM": "stellar", "ALGO": "algorand",
    "VET": "vechain", "FIL": "filecoin", "TRX": "tron", "ETC": "ethereum-classic",
    "XMR": "monero", "AAVE": "aave", "GRT": "the-graph", "SAND": "the-sandbox",
    "MANA": "decentraland", "CRO": "crypto-com-chain", "FTM": "fantom",
    "NEAR": "near", "ICP": "internet-computer", "APE": "apecoin",
    "OP": "optimism", "ARB": "arbitrum", "SUI": "sui", "INJ": "injective-protocol",
    "SEI": "sei-network", "TIA": "celestia", "PEPE": "pepe", "WIF": "dogwifcoin",
}


# ─────────────────────────────────────────────────────────────────────────────
# Cache layer  (TTL-based, in-memory)
# ─────────────────────────────────────────────────────────────────────────────
_cache: dict = {}

FX_TTL     = int(os.getenv("FX_CACHE_TTL_SECONDS",    "900"))   # 15 min
CRYPTO_TTL = int(os.getenv("CRYPTO_CACHE_TTL_SECONDS", "60"))   # 1 min
STOCK_TTL  = int(os.getenv("STOCK_CACHE_TTL_SECONDS",  "300"))  # 5 min


def _cached(key: str, ttl: int):
    entry = _cache.get(key)
    if entry and (time.time() - entry["ts"]) < ttl:
        return entry["data"]
    return None


def _store(key: str, data):
    _cache[key] = {"ts": time.time(), "data": data}
    return data


# ─────────────────────────────────────────────────────────────────────────────
# Live FX rates  (open.er-api.com – free, no key needed)
# Returns dict: symbol → units of that currency per 1 USD
# e.g. {"EUR": 0.873, "GBP": 0.754, "USD": 1.0, ...}
# ─────────────────────────────────────────────────────────────────────────────
FX_URL = os.getenv("FX_PROVIDER_URL", "https://open.er-api.com/v6/latest/USD")

_FALLBACK_FX = {"USD": 1.0, "EUR": 0.92, "GBP": 0.79, "CHF": 0.90,
                "CAD": 1.37, "AUD": 1.52, "JPY": 149.0}


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
            except Exception:
                pass
        logger.info(f"FX rates refreshed ({len(fx)} currencies)")
        return _store("fx", fx)
    except Exception as e:
        logger.warning(f"FX fetch failed: {e} — using fallback")
        return _FALLBACK_FX


# ─────────────────────────────────────────────────────────────────────────────
# Live crypto prices  (CoinGecko public API – free, no key needed)
# Returns dict: symbol → price in USD
# ─────────────────────────────────────────────────────────────────────────────
COINGECKO_URL = "https://api.coingecko.com/api/v3/simple/price"


def fetch_crypto_prices(symbols: set[str]) -> dict[str, float]:
    # Stablecoins always $1
    result = {s: 1.0 for s in symbols if s.upper() in STABLECOIN_SYMBOLS}
    needed = {s for s in symbols if s.upper() not in STABLECOIN_SYMBOLS}
    if not needed:
        return result

    # Map symbols to CoinGecko IDs
    id_to_symbol = {}
    unknown = []
    for sym in needed:
        cg_id = COINGECKO_IDS.get(sym.upper())
        if cg_id:
            id_to_symbol[cg_id] = sym.upper()
        else:
            # Try symbol directly as ID (works for many newer coins)
            id_to_symbol[sym.lower()] = sym.upper()
            unknown.append(sym)

    cached_key = "crypto_" + "_".join(sorted(id_to_symbol.keys()))
    cached = _cached(cached_key, CRYPTO_TTL)
    if cached:
        result.update(cached)
        return result

    try:
        ids_param = ",".join(id_to_symbol.keys())
        with httpx.Client(timeout=10.0) as c:
            r = c.get(COINGECKO_URL, params={
                "ids": ids_param,
                "vs_currencies": "usd",
            })
            r.raise_for_status()
            data = r.json()

        prices = {}
        for cg_id, sym in id_to_symbol.items():
            if cg_id in data and "usd" in data[cg_id]:
                prices[sym] = float(data[cg_id]["usd"])

        logger.info(f"CoinGecko prices fetched: {prices}")
        _store(cached_key, prices)
        result.update(prices)
    except Exception as e:
        logger.warning(f"CoinGecko fetch failed: {e}")

    return result


# ─────────────────────────────────────────────────────────────────────────────
# Live stock prices  (Yahoo Finance via yfinance – free, no key needed)
# Returns dict: symbol → price in USD
# ─────────────────────────────────────────────────────────────────────────────
def fetch_stock_prices(symbols: set[str]) -> dict[str, float]:
    if not symbols:
        return {}

    cached_key = "stocks_" + "_".join(sorted(symbols))
    cached = _cached(cached_key, STOCK_TTL)
    if cached:
        return cached

    try:
        import yfinance as yf
        tickers = yf.Tickers(" ".join(symbols))
        prices = {}
        for sym in symbols:
            try:
                info = tickers.tickers[sym].fast_info
                price = getattr(info, "last_price", None) or getattr(info, "regular_market_price", None)
                if price and price > 0:
                    prices[sym.upper()] = float(price)
            except Exception as e:
                logger.warning(f"yfinance price fetch failed for {sym}: {e}")
        logger.info(f"Stock prices fetched: {prices}")
        return _store(cached_key, prices)
    except ImportError:
        logger.warning("yfinance not installed — stock prices unavailable")
        return {}
    except Exception as e:
        logger.warning(f"Stock price fetch failed: {e}")
        return {}


# ─────────────────────────────────────────────────────────────────────────────
# Master price resolver  – given a set of assets, return price_usd for each
# ─────────────────────────────────────────────────────────────────────────────
def get_prices_usd(assets: list, fx_to_usd: dict) -> dict[str, float]:
    """
    Returns {symbol_upper: price_in_usd} for all assets.
    - Fiat:       derived from fx_to_usd (1 unit = 1/fx_rate USD)
    - Stablecoin: always 1.0
    - Crypto:     CoinGecko live
    - Stock/ETF:  yfinance live
    """
    prices = {}

    crypto_symbols = set()
    stock_symbols  = set()

    for asset in assets:
        sym = asset.symbol.upper()
        cls = asset.asset_class.lower()

        if sym in FIAT_SYMBOLS or cls == "fiat":
            rate = fx_to_usd.get(sym, 1.0)
            prices[sym] = (1.0 / rate) if rate > 0 else 1.0

        elif sym in STABLECOIN_SYMBOLS or cls == "stablecoin":
            prices[sym] = 1.0

        elif cls == "crypto":
            crypto_symbols.add(sym)

        elif cls in ("stock", "etf"):
            stock_symbols.add(sym)

        else:
            # Unknown – default to 0
            prices[sym] = 0.0

    if crypto_symbols:
        prices.update(fetch_crypto_prices(crypto_symbols))

    if stock_symbols:
        prices.update(fetch_stock_prices(stock_symbols))

    return prices


# ─────────────────────────────────────────────────────────────────────────────
# FX conversion helper
# fx_to_usd[X] = units of X per 1 USD  (e.g. EUR=0.873 means 1 USD = 0.873 EUR)
# ─────────────────────────────────────────────────────────────────────────────
def usd_to_base(value_usd: float, base_currency: str, fx_to_usd: dict) -> float:
    rate = fx_to_usd.get(base_currency.upper(), 1.0)
    # value_base = value_usd * rate  (multiply, because rate = base_units per USD)
    return value_usd * rate if rate > 0 else value_usd


# ─────────────────────────────────────────────────────────────────────────────
# /rates  endpoint
# ─────────────────────────────────────────────────────────────────────────────
@app.get("/rates")
def get_rates(db: Session = Depends(get_db)):
    fx_to_usd = fetch_fx_rates()

    # Build live prices for all assets currently in the DB
    all_assets = db.query(models.Asset).all()
    live_prices = get_prices_usd(all_assets, fx_to_usd)

    return {
        "base_reference": "USD",
        "prices": live_prices,
        "fx_to_usd": fx_to_usd,
        "fx_source": "live",
    }


# ─────────────────────────────────────────────────────────────────────────────
# /valuation  endpoint
# ─────────────────────────────────────────────────────────────────────────────
@app.get("/valuation")
def valuation(base_currency: str = "EUR", db: Session = Depends(get_db)):
    fx_to_usd = fetch_fx_rates()

    holdings = db.query(models.Holding).all()
    assets   = {a.id: a for a in db.query(models.Asset).all()}
    accounts = {a.id: a for a in db.query(models.Account).all()}

    # Resolve live prices for every distinct asset held
    held_assets = [assets[h.asset_id] for h in holdings if h.asset_id in assets]
    price_map   = get_prices_usd(list({a.id: a for a in held_assets}.values()), fx_to_usd)

    portfolio_items  = []
    total_value_base = 0.0
    cash_total       = 0.0
    crypto_total     = 0.0
    stock_total      = 0.0

    base_upper = base_currency.upper()

    for holding in holdings:
        asset   = assets.get(holding.asset_id)
        account = accounts.get(holding.account_id)
        if not asset or not account:
            continue

        sym       = asset.symbol.upper()
        cls       = asset.asset_class.lower()
        price_usd = price_map.get(sym, 0.0)
        value_usd = holding.quantity * price_usd
        value_base = usd_to_base(value_usd, base_upper, fx_to_usd)

        portfolio_items.append({
            "holding_id":   holding.id,
            "account_id":   account.id,
            "account_name": account.name,
            "asset_id":     asset.id,
            "symbol":       asset.symbol,
            "asset_name":   asset.name,
            "asset_class":  asset.asset_class,
            "quantity":     holding.quantity,
            "avg_cost":     holding.avg_cost,
            "price_usd":    round(price_usd, 6),
            "value_in_base": round(value_base, 2),
            "base_currency": base_upper,
        })

        total_value_base += value_base

        if cls == "fiat":
            cash_total += value_base
        elif cls in ("crypto", "stablecoin"):
            crypto_total += value_base
        elif cls in ("stock", "etf"):
            stock_total += value_base

    recent_events = (
        db.query(models.TransactionEvent)
        .order_by(models.TransactionEvent.date.desc())
        .limit(10)
        .all()
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


# ─────────────────────────────────────────────────────────────────────────────
# Accounts
# ─────────────────────────────────────────────────────────────────────────────
@app.get("/")
def root():
    return {"status": "ok", "message": "LedgerVault API v4 running — live prices enabled"}


@app.post("/reset")
def reset_database():
    Base.metadata.drop_all(bind=engine)
    Base.metadata.create_all(bind=engine)
    return {"status": "ok", "message": "database reset complete"}


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
        raise HTTPException(status_code=404, detail="Account not found")
    if payload.name is not None:         item.name = payload.name
    if payload.account_type is not None: item.account_type = payload.account_type
    if payload.base_currency is not None: item.base_currency = payload.base_currency.upper()
    db.commit(); db.refresh(item)
    return item


@app.delete("/accounts/{account_id}")
def delete_account(account_id: str, db: Session = Depends(get_db)):
    item = db.query(models.Account).filter(models.Account.id == account_id).first()
    if not item:
        raise HTTPException(status_code=404, detail="Account not found")
    has_legs     = db.query(models.TransactionLeg).filter(models.TransactionLeg.account_id == account_id).first()
    has_holdings = db.query(models.Holding).filter(models.Holding.account_id == account_id).first()
    if has_legs or has_holdings:
        raise HTTPException(status_code=400,
            detail="Cannot delete account with activity or holdings. Delete related transactions first.")
    db.delete(item); db.commit()
    return {"status": "ok"}


# ─────────────────────────────────────────────────────────────────────────────
# Assets
# ─────────────────────────────────────────────────────────────────────────────
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


# ─────────────────────────────────────────────────────────────────────────────
# Holdings
# ─────────────────────────────────────────────────────────────────────────────
@app.get("/holdings", response_model=HoldingList)
def list_holdings(db: Session = Depends(get_db)):
    return {"items": db.query(models.Holding).all()}


# ─────────────────────────────────────────────────────────────────────────────
# Transaction Events
# ─────────────────────────────────────────────────────────────────────────────
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
            raise HTTPException(status_code=404, detail="Transaction event not found")

        legs = db.query(models.TransactionLeg).filter(models.TransactionLeg.event_id == event_id).all()
        for leg in legs:
            holding = db.query(models.Holding).filter(
                models.Holding.account_id == leg.account_id,
                models.Holding.asset_id   == leg.asset_id,
            ).first()
            if holding:
                new_qty = holding.quantity - leg.quantity
                if new_qty <= 0:
                    db.delete(holding)
                else:
                    holding.quantity = new_qty
            db.delete(leg)

        db.flush()
        db.delete(event)
        db.commit()
        return {"status": "ok"}
    except HTTPException:
        db.rollback(); raise
    except Exception as e:
        db.rollback()
        raise HTTPException(status_code=500, detail=f"Delete failed: {str(e)}")


@app.post("/transaction-events", response_model=TransactionEventOut)
def create_transaction_event(payload: TransactionEventCreate, db: Session = Depends(get_db)):
    if not payload.legs:
        raise HTTPException(status_code=400, detail="At least one leg is required")

    event = models.TransactionEvent(
        id=str(uuid4()), event_type=payload.event_type, category=payload.category,
        description=payload.description, date=payload.date, note=payload.note,
        source=payload.source, external_id=payload.external_id,
    )
    db.add(event); db.flush()

    for leg in payload.legs:
        account = db.query(models.Account).filter(models.Account.id == leg.account_id).first()
        if not account:
            raise HTTPException(status_code=404, detail=f"Account not found: {leg.account_id}")

        asset = db.query(models.Asset).filter(models.Asset.id == leg.asset_id).first()
        if not asset:
            raise HTTPException(status_code=404, detail=f"Asset not found: {leg.asset_id}")

        holding = db.query(models.Holding).filter(
            models.Holding.account_id == leg.account_id,
            models.Holding.asset_id   == leg.asset_id,
        ).first()

        if not holding:
            holding = models.Holding(
                id=str(uuid4()), account_id=leg.account_id, asset_id=leg.asset_id,
                quantity=0.0, avg_cost=0.0,
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
            id=str(uuid4()), event_id=event.id, account_id=leg.account_id,
            asset_id=leg.asset_id, quantity=leg.quantity, unit_price=leg.unit_price,
            fee_flag="true" if leg.fee_flag else "false",
        ))

    db.commit(); db.refresh(event)
    return event


# ─────────────────────────────────────────────────────────────────────────────
# Seed  (expanded with more common assets)
# ─────────────────────────────────────────────────────────────────────────────
@app.post("/seed")
def seed_data(db: Session = Depends(get_db)):
    seed_assets = [
        # Fiat
        ("EUR",  "Euro",             "fiat",   "EUR"),
        ("USD",  "US Dollar",        "fiat",   "USD"),
        ("GBP",  "British Pound",    "fiat",   "GBP"),
        ("CHF",  "Swiss Franc",      "fiat",   "CHF"),
        ("CAD",  "Canadian Dollar",  "fiat",   "CAD"),
        ("AUD",  "Australian Dollar","fiat",   "AUD"),
        ("JPY",  "Japanese Yen",     "fiat",   "JPY"),
        ("PLN",  "Polish Zloty",     "fiat",   "PLN"),
        # Stablecoins
        ("USDT", "Tether",           "crypto", "USD"),
        ("USDC", "USD Coin",         "crypto", "USD"),
        ("DAI",  "Dai",              "crypto", "USD"),
        # Crypto
        ("BTC",  "Bitcoin",          "crypto", "USD"),
        ("ETH",  "Ethereum",         "crypto", "USD"),
        ("SOL",  "Solana",           "crypto", "USD"),
        ("BNB",  "BNB",              "crypto", "USD"),
        ("XRP",  "XRP",              "crypto", "USD"),
        ("ADA",  "Cardano",          "crypto", "USD"),
        ("DOGE", "Dogecoin",         "crypto", "USD"),
        ("AVAX", "Avalanche",        "crypto", "USD"),
        ("DOT",  "Polkadot",         "crypto", "USD"),
        ("MATIC","Polygon",          "crypto", "USD"),
        ("LINK", "Chainlink",        "crypto", "USD"),
        # Stocks
        ("AAPL", "Apple Inc.",       "stock",  "USD"),
        ("TSLA", "Tesla Inc.",       "stock",  "USD"),
        ("MSFT", "Microsoft Corp.",  "stock",  "USD"),
        ("NVDA", "NVIDIA Corp.",     "stock",  "USD"),
        ("GOOGL","Alphabet Inc.",    "stock",  "USD"),
        ("AMZN", "Amazon.com Inc.",  "stock",  "USD"),
        ("META", "Meta Platforms",   "stock",  "USD"),
        ("NFLX", "Netflix Inc.",     "stock",  "USD"),
        ("AMD",  "AMD Inc.",         "stock",  "USD"),
        ("INTC", "Intel Corp.",      "stock",  "USD"),
        ("BABA", "Alibaba Group",    "stock",  "USD"),
        ("DIS",  "Walt Disney Co.",  "stock",  "USD"),
        ("PYPL", "PayPal Holdings",  "stock",  "USD"),
        ("SQ",   "Block Inc.",       "stock",  "USD"),
        ("COIN", "Coinbase Global",  "stock",  "USD"),
    ]
    count = 0
    for symbol, name, asset_class, quote_currency in seed_assets:
        existing = db.query(models.Asset).filter(models.Asset.symbol == symbol).first()
        if not existing:
            db.add(models.Asset(
                id=str(uuid4()), symbol=symbol, name=name,
                asset_class=asset_class, quote_currency=quote_currency,
            ))
            count += 1
    db.commit()
    return {"status": "ok", "added": count}