from uuid import uuid4
from fastapi import FastAPI, Depends, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy.orm import Session
import time, os, httpx, logging

from app.db import engine, SessionLocal, Base
from app import models
from app.schemas import (
    AccountList, AccountOut, AccountCreate, AccountUpdate,
    AssetList, AssetOut, AssetCreate,
    HoldingList,
    TransactionEventList, TransactionEventOut, TransactionEventCreate,
    TransactionLegList
)

app = FastAPI(title="LedgerVault API", version="4.0.0")
models.Base.metadata.create_all(bind=engine)
logger = logging.getLogger("ledgervault")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"], allow_credentials=True,
    allow_methods=["*"], allow_headers=["*"],
)

def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()

# ─────────────────────────────────────────────
# FX  (open.er-api.com — free, no key)
# ─────────────────────────────────────────────
FX_PROVIDER_URL      = os.getenv("FX_PROVIDER_URL", "https://open.er-api.com/v6/latest/USD")
FX_CACHE_TTL_SECONDS = int(os.getenv("FX_CACHE_TTL_SECONDS", "900"))
_fx_cache = {"ts": 0.0, "fx_to_usd": None}

FALLBACK_FX = {
    "USD":1.0,"EUR":1.08,"GBP":1.27,"CHF":0.90,"CAD":0.74,"AUD":0.65,
    "JPY":0.0067,"PLN":0.25,"SEK":0.096,"NOK":0.093,"CZK":0.044,
    "HKD":0.128,"SGD":0.74,"NZD":0.60,"DKK":0.145,"HUF":0.0028,
    "RON":0.22,"TRY":0.031,"INR":0.012,"BRL":0.20,
}

def _fetch_live_fx() -> dict:
    now = time.time()
    if _fx_cache["fx_to_usd"] and (now - _fx_cache["ts"]) < FX_CACHE_TTL_SECONDS:
        return _fx_cache["fx_to_usd"]
    try:
        with httpx.Client(timeout=8.0) as c:
            r = c.get(FX_PROVIDER_URL); r.raise_for_status()
            rates = r.json().get("rates", {})
        # open.er-api.com returns "currency per USD" (e.g. EUR=0.87 means 1 USD = 0.87 EUR).
        # We store as "USD per currency unit" (e.g. EUR=1.149 means 1 EUR = $1.149),
        # matching the FALLBACK_FX convention and convert_usd_to_base (which divides by rate).
        fx = {"USD": 1.0}
        for k, v in rates.items():
            try:
                val = float(v)
                if val > 0: fx[str(k).upper()] = 1.0 / val
            except: pass
        _fx_cache.update({"ts": now, "fx_to_usd": fx})
        return fx
    except Exception:
        logger.exception("FX fetch failed")
        return FALLBACK_FX

def convert_usd_to_base(value_usd: float, base: str, fx: dict) -> float:
    rate = fx.get(base.upper(), 1.0)
    return value_usd / rate if rate else value_usd

# ─────────────────────────────────────────────
# CRYPTO PRICES  (CoinGecko — free, no key)
# ─────────────────────────────────────────────
CRYPTO_CACHE_TTL = int(os.getenv("CRYPTO_CACHE_TTL_SECONDS", "120"))
_crypto_cache = {"ts": 0.0, "prices": {}}   # symbol.upper() → price_usd

COINGECKO_TOP_URL = (
    "https://api.coingecko.com/api/v3/coins/markets"
    "?vs_currency=usd&order=market_cap_desc&per_page=250&page=1"
    "&sparkline=false&price_change_percentage=24h"
)
COINGECKO_SEARCH_URL = "https://api.coingecko.com/api/v3/search?query={q}"
COINGECKO_PRICE_URL  = (
    "https://api.coingecko.com/api/v3/simple/price"
    "?ids={ids}&vs_currencies=usd&include_24hr_change=true"
)

def _fetch_crypto_prices() -> dict:
    now = time.time()
    if _crypto_cache["prices"] and (now - _crypto_cache["ts"]) < CRYPTO_CACHE_TTL:
        return _crypto_cache["prices"]
    try:
        with httpx.Client(timeout=10.0) as c:
            r = c.get(COINGECKO_TOP_URL); r.raise_for_status()
            coins = r.json()
        prices = {}
        for coin in coins:
            sym = coin.get("symbol","").upper()
            p   = coin.get("current_price")
            if sym and p is not None:
                prices[sym] = float(p)
        _crypto_cache.update({"ts": now, "prices": prices})
        return prices
    except Exception:
        logger.exception("CoinGecko prices fetch failed")
        return _crypto_cache.get("prices", {})

# ─────────────────────────────────────────────
# STOCK PRICES  (Yahoo Finance — free, no key)
# ─────────────────────────────────────────────
STOCK_CACHE_TTL = int(os.getenv("STOCK_CACHE_TTL_SECONDS", "300"))
_stock_cache: dict[str, dict] = {}   # symbol → {price, change_pct, exchange, name, ts}

def _fetch_stock_price(symbol: str) -> dict | None:
    sym = symbol.upper()
    cached = _stock_cache.get(sym)
    if cached and (time.time() - cached["ts"]) < STOCK_CACHE_TTL:
        return cached
    try:
        url = f"https://query1.finance.yahoo.com/v8/finance/chart/{sym}?interval=1d&range=1d"
        with httpx.Client(timeout=8.0, headers={"User-Agent": "Mozilla/5.0"}) as c:
            r = c.get(url); r.raise_for_status()
            data = r.json()
        meta = data["chart"]["result"][0]["meta"]
        price  = float(meta.get("regularMarketPrice", 0))
        prev   = float(meta.get("chartPreviousClose", price) or price)
        chg    = ((price - prev) / prev * 100) if prev else 0.0
        exch   = meta.get("exchangeName", meta.get("fullExchangeName", ""))
        name   = meta.get("shortName", sym)
        mstate = meta.get("marketState", "CLOSED")   # REGULAR / PRE / POST / CLOSED
        result = {
            "symbol": sym, "price": price, "change_pct": round(chg, 2),
            "exchange": exch, "name": name,
            "currency": meta.get("currency", "USD"),
            "market_state": mstate, "ts": time.time()
        }
        _stock_cache[sym] = result
        return result
    except Exception as e:
        logger.warning(f"Yahoo stock fetch failed for {sym}: {e}")
        return None

# ─────────────────────────────────────────────
# ASSET RESOLUTION HELPER
# ─────────────────────────────────────────────
def _resolve_asset(leg_asset_id: str, account: models.Account, db: Session) -> models.Asset:
    if leg_asset_id:
        asset = db.query(models.Asset).filter(models.Asset.id == leg_asset_id).first()
        if not asset:
            raise HTTPException(status_code=404, detail=f"Asset not found: {leg_asset_id}")
        return asset
    currency = account.base_currency.upper()
    asset = db.query(models.Asset).filter(models.Asset.symbol == currency).first()
    if not asset:
        asset = models.Asset(
            id=str(uuid4()), symbol=currency, name=currency,
            asset_class="fiat", quote_currency=currency,
        )
        db.add(asset); db.flush()
        logger.info(f"Auto-created fiat asset: {currency}")
    return asset

# ─────────────────────────────────────────────
# ROUTES
# ─────────────────────────────────────────────
@app.get("/")
def root():
    return {"status": "ok", "message": "LedgerVault API v4.0 — live prices enabled"}

@app.post("/reset")
def reset_database():
    Base.metadata.drop_all(bind=engine)
    Base.metadata.create_all(bind=engine)
    return {"status": "ok"}

# ── Rates (FX + live crypto) ──────────────────
@app.get("/rates")
def get_rates():
    try:
        fx = _fetch_live_fx()
        fx_source = "live"
    except Exception:
        fx = FALLBACK_FX; fx_source = "fallback"

    crypto_prices = _fetch_crypto_prices()

    # Merge: crypto prices take priority; fiat symbols use FX rates
    prices = {}
    for sym, rate in fx.items():
        prices[sym] = 1.0 / rate if rate else 1.0   # value in USD
    prices.update(crypto_prices)   # crypto overrides

    return {
        "base_reference": "USD",
        "prices": prices,
        "fx_to_usd": fx,
        "fx_source": fx_source,
        "crypto_count": len(crypto_prices),
    }

# ── Search: crypto ────────────────────────────
@app.get("/search/crypto")
def search_crypto(q: str = Query(..., min_length=1), db: Session = Depends(get_db)):
    try:
        url = COINGECKO_SEARCH_URL.format(q=q)
        with httpx.Client(timeout=8.0) as c:
            r = c.get(url); r.raise_for_status()
            results = r.json().get("coins", [])

        crypto_prices = _fetch_crypto_prices()
        fx = _fetch_live_fx()

        hits = []
        for coin in results[:20]:
            sym   = coin.get("symbol","").upper()
            name  = coin.get("name","")
            cg_id = coin.get("id","")
            price_usd = crypto_prices.get(sym)

            # If price not in cache, try fetching by coingecko id
            if price_usd is None and cg_id:
                try:
                    with httpx.Client(timeout=5.0) as c2:
                        pr = c2.get(COINGECKO_PRICE_URL.format(ids=cg_id))
                        pr.raise_for_status()
                        pd = pr.json().get(cg_id, {})
                        price_usd = pd.get("usd")
                        if price_usd:
                            _crypto_cache["prices"][sym] = float(price_usd)
                except: pass

            hits.append({
                "symbol": sym,
                "name": name,
                "coingecko_id": cg_id,
                "thumb": coin.get("thumb",""),
                "market_cap_rank": coin.get("market_cap_rank"),
                "price_usd": price_usd,
                "asset_class": "crypto",
                "quote_currency": "USD",
            })
        return {"results": hits}
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"CoinGecko search failed: {e}")

# ── Search: stocks ────────────────────────────
@app.get("/search/stocks")
def search_stocks(q: str = Query(..., min_length=1)):
    try:
        url = f"https://query1.finance.yahoo.com/v1/finance/search?q={q}&quotesCount=15&newsCount=0"
        with httpx.Client(timeout=8.0, headers={"User-Agent": "Mozilla/5.0"}) as c:
            r = c.get(url); r.raise_for_status()
            quotes = r.json().get("quotes", [])

        results = []
        for q_item in quotes:
            qtype = q_item.get("quoteType","")
            if qtype not in ("EQUITY","ETF","MUTUALFUND"): continue
            sym    = q_item.get("symbol","")
            name   = q_item.get("longname") or q_item.get("shortname") or sym
            exch   = q_item.get("exchDisp") or q_item.get("exchange","")
            exch_code = q_item.get("exchange","")
            results.append({
                "symbol": sym,
                "name": name,
                "exchange": exch,
                "exchange_code": exch_code,
                "type": qtype,
                "asset_class": "etf" if qtype == "ETF" else "stock",
                "quote_currency": "USD",
            })

        # Enrich top 5 with live price
        for item in results[:5]:
            info = _fetch_stock_price(item["symbol"])
            if info:
                item["price_usd"]   = info["price"]
                item["change_pct"]  = info["change_pct"]
                item["market_state"]= info["market_state"]
                item["exchange"]    = info.get("exchange", item["exchange"])
                item["name"]        = info.get("name", item["name"])

        return {"results": results}
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"Yahoo search failed: {e}")

# ── Stock quote (single) ──────────────────────
@app.get("/quote/stock/{symbol}")
def get_stock_quote(symbol: str):
    info = _fetch_stock_price(symbol.upper())
    if not info:
        raise HTTPException(status_code=404, detail=f"Could not fetch quote for {symbol}")
    return info

# ── Crypto quote (single) ─────────────────────
@app.get("/quote/crypto/{symbol}")
def get_crypto_quote(symbol: str):
    sym = symbol.upper()
    prices = _fetch_crypto_prices()
    price = prices.get(sym)
    if price is None:
        raise HTTPException(status_code=404, detail=f"Price not found for {sym}")
    return {"symbol": sym, "price_usd": price}

# ── Valuation ─────────────────────────────────
@app.get("/valuation")
def valuation(base_currency: str = "EUR", db: Session = Depends(get_db)):
    try: fx = _fetch_live_fx()
    except: fx = FALLBACK_FX

    crypto_prices = _fetch_crypto_prices()
    holdings  = db.query(models.Holding).all()
    assets    = {a.id: a for a in db.query(models.Asset).all()}
    accounts  = {a.id: a for a in db.query(models.Account).all()}

    portfolio_items = []
    total_base = cash_total = crypto_total = stock_total = 0.0

    for holding in holdings:
        asset   = assets.get(holding.asset_id)
        account = accounts.get(holding.account_id)
        if not asset or not account: continue

        sym = asset.symbol.upper()

        # Determine price in USD
        if asset.asset_class == "fiat":
            rate = fx.get(sym, 1.0)
            price_usd = 1.0 / rate if rate else 1.0
        elif asset.asset_class == "crypto":
            price_usd = crypto_prices.get(sym, 0.0)
        elif asset.asset_class in ("stock","etf"):
            info = _fetch_stock_price(sym)
            price_usd = info["price"] if info else 0.0
        else:
            price_usd = 0.0

        value_usd  = holding.quantity * price_usd
        value_base = convert_usd_to_base(value_usd, base_currency, fx)

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
            "price_usd":    price_usd,
            "value_in_base":round(value_base, 2),
            "base_currency":base_currency.upper(),
        })

        total_base += value_base
        if asset.asset_class == "fiat":          cash_total   += value_base
        elif asset.asset_class == "crypto":       crypto_total += value_base
        elif asset.asset_class in ("stock","etf"):stock_total  += value_base

    recent_events = (
        db.query(models.TransactionEvent)
        .order_by(models.TransactionEvent.date.desc())
        .all()[:10]
    )

    return {
        "base_currency":   base_currency.upper(),
        "total":           round(total_base, 2),
        "cash":            round(cash_total, 2),
        "crypto":          round(crypto_total, 2),
        "stocks":          round(stock_total, 2),
        "portfolio":       portfolio_items,
        "recent_activity": [
            {
                "id": e.id, "event_type": e.event_type, "category": e.category,
                "description": e.description, "date": e.date, "note": e.note,
            }
            for e in recent_events
        ],
    }

# ── Accounts ──────────────────────────────────
@app.get("/accounts", response_model=AccountList)
def list_accounts(db: Session = Depends(get_db)):
    return {"items": db.query(models.Account).all()}

@app.post("/accounts", response_model=AccountOut)
def create_account(payload: AccountCreate, db: Session = Depends(get_db)):
    item = models.Account(id=str(uuid4()), name=payload.name,
                          account_type=payload.account_type,
                          base_currency=payload.base_currency.upper())
    db.add(item); db.commit(); db.refresh(item); return item

@app.put("/accounts/{account_id}", response_model=AccountOut)
def update_account(account_id: str, payload: AccountUpdate, db: Session = Depends(get_db)):
    item = db.query(models.Account).filter(models.Account.id == account_id).first()
    if not item: raise HTTPException(status_code=404, detail="Account not found")
    if payload.name is not None:          item.name          = payload.name
    if payload.account_type is not None:  item.account_type  = payload.account_type
    if payload.base_currency is not None: item.base_currency = payload.base_currency.upper()
    db.commit(); db.refresh(item); return item

@app.delete("/accounts/{account_id}")
def delete_account(account_id: str, db: Session = Depends(get_db)):
    item = db.query(models.Account).filter(models.Account.id == account_id).first()
    if not item: raise HTTPException(status_code=404, detail="Account not found")
    has_legs = db.query(models.TransactionLeg).filter(
        models.TransactionLeg.account_id == account_id).first() is not None
    has_holdings = db.query(models.Holding).filter(
        models.Holding.account_id == account_id).first() is not None
    if has_legs or has_holdings:
        raise HTTPException(status_code=400,
            detail="Cannot delete account with activity or holdings.")
    db.delete(item); db.commit(); return {"status": "ok"}

# ── Assets ────────────────────────────────────
@app.get("/assets", response_model=AssetList)
def list_assets(db: Session = Depends(get_db)):
    return {"items": db.query(models.Asset).all()}

@app.post("/assets", response_model=AssetOut)
def create_asset(payload: AssetCreate, db: Session = Depends(get_db)):
    existing = db.query(models.Asset).filter(
        models.Asset.symbol == payload.symbol.upper()).first()
    if existing: return existing
    item = models.Asset(id=str(uuid4()), symbol=payload.symbol.upper(),
                        name=payload.name, asset_class=payload.asset_class,
                        quote_currency=payload.quote_currency.upper())
    db.add(item); db.commit(); db.refresh(item); return item

# ── Holdings ──────────────────────────────────
@app.get("/holdings", response_model=HoldingList)
def list_holdings(db: Session = Depends(get_db)):
    return {"items": db.query(models.Holding).all()}

# ── Transaction events ────────────────────────
@app.get("/transaction-events", response_model=TransactionEventList)
def list_transaction_events(account_id: str = None, db: Session = Depends(get_db)):
    if account_id:
        ids = [r[0] for r in db.query(models.TransactionLeg.event_id)
               .filter(models.TransactionLeg.account_id == account_id).distinct().all()]
        items = (db.query(models.TransactionEvent)
                 .filter(models.TransactionEvent.id.in_(ids))
                 .order_by(models.TransactionEvent.date.desc()).all())
    else:
        items = (db.query(models.TransactionEvent)
                 .order_by(models.TransactionEvent.date.desc()).all())
    return {"items": items}

@app.get("/transaction-legs", response_model=TransactionLegList)
def list_transaction_legs(db: Session = Depends(get_db)):
    return {"items": db.query(models.TransactionLeg).all()}

@app.delete("/transaction-events/{event_id}")
def delete_transaction_event(event_id: str, db: Session = Depends(get_db)):
    try:
        event = db.query(models.TransactionEvent).filter(
            models.TransactionEvent.id == event_id).first()
        if not event: raise HTTPException(status_code=404, detail="Event not found")
        legs = db.query(models.TransactionLeg).filter(
            models.TransactionLeg.event_id == event_id).all()
        for leg in legs:
            holding = db.query(models.Holding).filter(
                models.Holding.account_id == leg.account_id,
                models.Holding.asset_id == leg.asset_id).first()
            if holding:
                new_qty = holding.quantity - leg.quantity
                if new_qty <= 0: db.delete(holding)
                else: holding.quantity = new_qty
            db.delete(leg)
        db.flush(); db.delete(event); db.commit()
        return {"status": "ok"}
    except HTTPException: db.rollback(); raise
    except Exception as e: db.rollback(); raise HTTPException(status_code=500, detail=str(e))

@app.post("/transaction-events", response_model=TransactionEventOut)
def create_transaction_event(payload: TransactionEventCreate, db: Session = Depends(get_db)):
    if not payload.legs:
        raise HTTPException(status_code=400, detail="At least one leg required")

    event = models.TransactionEvent(
        id=str(uuid4()), event_type=payload.event_type, category=payload.category,
        description=payload.description, date=payload.date, note=payload.note,
        source=payload.source, external_id=payload.external_id,
    )
    db.add(event); db.flush()

    for leg in payload.legs:
        account = db.query(models.Account).filter(
            models.Account.id == leg.account_id).first()
        if not account:
            raise HTTPException(status_code=404, detail=f"Account not found: {leg.account_id}")

        asset = _resolve_asset(leg.asset_id or "", account, db)

        holding = db.query(models.Holding).filter(
            models.Holding.account_id == leg.account_id,
            models.Holding.asset_id == asset.id).first()
        if not holding:
            holding = models.Holding(id=str(uuid4()), account_id=leg.account_id,
                                     asset_id=asset.id, quantity=0.0, avg_cost=0.0)
            db.add(holding); db.flush()

        old_qty = holding.quantity
        new_qty = old_qty + leg.quantity
        if leg.quantity > 0 and leg.unit_price is not None:
            existing_val = old_qty * holding.avg_cost
            new_val = leg.quantity * leg.unit_price
            if new_qty > 0:
                holding.avg_cost = (existing_val + new_val) / new_qty
        holding.quantity = max(new_qty, 0.0)
        if holding.quantity == 0: db.delete(holding)

        db.add(models.TransactionLeg(
            id=str(uuid4()), event_id=event.id,
            account_id=leg.account_id, asset_id=asset.id,
            quantity=leg.quantity, unit_price=leg.unit_price,
            fee_flag="true" if leg.fee_flag else "false",
        ))

    db.commit(); db.refresh(event); return event

# ── Seed ──────────────────────────────────────
@app.post("/seed")
def seed_data(db: Session = Depends(get_db)):
    seeds = [
        ("EUR","Euro","fiat","EUR"),("USD","US Dollar","fiat","USD"),
        ("GBP","British Pound","fiat","GBP"),("CHF","Swiss Franc","fiat","CHF"),
        ("CAD","Canadian Dollar","fiat","CAD"),("AUD","Australian Dollar","fiat","AUD"),
        ("JPY","Japanese Yen","fiat","JPY"),("PLN","Polish Zloty","fiat","PLN"),
        ("SEK","Swedish Krona","fiat","SEK"),("NOK","Norwegian Krone","fiat","NOK"),
        ("CZK","Czech Koruna","fiat","CZK"),
        ("USDT","Tether","crypto","USD"),("USDC","USD Coin","crypto","USD"),
        ("BTC","Bitcoin","crypto","USD"),("ETH","Ethereum","crypto","USD"),
        ("SOL","Solana","crypto","USD"),("XRP","XRP","crypto","USD"),
        ("TSLA","Tesla","stock","USD"),("AAPL","Apple","stock","USD"),
        ("NVDA","NVIDIA","stock","USD"),("MSFT","Microsoft","stock","USD"),
    ]
    for sym, name, cls, quote in seeds:
        if not db.query(models.Asset).filter(models.Asset.symbol == sym).first():
            db.add(models.Asset(id=str(uuid4()), symbol=sym, name=name,
                                asset_class=cls, quote_currency=quote))
    db.commit()
    return {"status": "ok"}
