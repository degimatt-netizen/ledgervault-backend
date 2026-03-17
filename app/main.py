from uuid import uuid4
from fastapi import FastAPI, Depends, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy.orm import Session
import time, os, httpx, logging, hmac, hashlib, base64, urllib.parse
from datetime import datetime, timedelta, timezone
from concurrent.futures import ThreadPoolExecutor, as_completed

from app.db import engine, SessionLocal, Base
from app import models
from app.schemas import (
    AccountList, AccountOut, AccountCreate, AccountUpdate,
    AssetList, AssetOut, AssetCreate,
    HoldingList,
    TransactionEventList, TransactionEventOut, TransactionEventCreate,
    TransactionLegList,
    ExchangeConnectionCreate, ExchangeConnectionOut, ExchangeConnectionList, SyncResult,
    RecurringTransactionCreate, RecurringTransactionUpdate,
    RecurringTransactionOut, RecurringTransactionList,
    BankConnectionOut, BankConnectionList, BankAuthUrlResponse, BankCallbackResponse,
)

app = FastAPI(title="LedgerVault API", version="4.2.0")
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
                # API gives "foreign per USD"; invert to "USD per foreign" to match FALLBACK_FX
                if float(v) > 0: fx[str(k).upper()] = 1.0 / float(v)
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
        exch_code = meta.get("exchangeName", "")
        exch_full = meta.get("fullExchangeName", exch_code)
        exchange_map = {
            "NMS": "NASDAQ", "NGM": "NASDAQ", "NCM": "NASDAQ",
            "NYQ": "NYSE", "ASE": "NYSE American",
            "PCX": "NYSE Arca", "BTS": "BATS",
            "NasdaqGS": "NASDAQ", "NasdaqGM": "NASDAQ", "NasdaqCM": "NASDAQ",
        }
        exch = exchange_map.get(exch_code, exch_full or exch_code)
        name   = meta.get("shortName", sym)
        mstate = meta.get("marketState", "CLOSED")
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
# EXCHANGE SYNC HELPERS
# ─────────────────────────────────────────────

def _ms_timestamp() -> int:
    return int(time.time() * 1000)

def _utc_now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def _hmac_sha256(secret: str, message: str) -> str:
    return hmac.new(secret.encode(), message.encode(), hashlib.sha256).hexdigest()

def _hmac_sha512(secret: str, message: bytes) -> bytes:
    return hmac.new(secret.encode(), message, hashlib.sha512).digest()


def _sync_binance(conn: models.ExchangeConnection, db: Session) -> SyncResult:
    """Fetch all trades from Binance and import new ones."""
    imported, skipped, errors = 0, 0, []
    base = "https://api.binance.com"

    # Fetch all symbols that the user holds
    try:
        ts = _ms_timestamp()
        params = f"timestamp={ts}"
        sig = _hmac_sha256(conn.api_secret, params)
        headers = {"X-MBX-APIKEY": conn.api_key}
        with httpx.Client(timeout=10.0) as c:
            r = c.get(f"{base}/api/v3/account?{params}&signature={sig}", headers=headers)
            r.raise_for_status()
            account_data = r.json()
    except Exception as e:
        return SyncResult(imported=0, skipped=0, errors=[f"Binance auth failed: {e}"], status="error")

    # Get balances with non-zero amounts to infer traded symbols
    balances = [b["asset"] for b in account_data.get("balances", []) if float(b.get("free", 0)) + float(b.get("locked", 0)) > 0]

    # Fetch recent trades for known base pairs (against USDT, BTC, ETH, BNB)
    quote_assets = ["USDT", "BUSD", "BTC", "ETH", "BNB", "EUR", "USD"]
    traded_pairs = set()
    for base_asset in balances:
        for quote in quote_assets:
            if base_asset != quote:
                traded_pairs.add(f"{base_asset}{quote}")

    # Fetch trade history for each pair (limit to last 500)
    all_trades = []
    with httpx.Client(timeout=10.0) as c:
        for symbol in list(traded_pairs)[:30]:  # cap at 30 pairs
            try:
                ts = _ms_timestamp()
                params = f"symbol={symbol}&limit=500&timestamp={ts}"
                sig = _hmac_sha256(conn.api_secret, params)
                r = c.get(f"{base}/api/v3/myTrades?{params}&signature={sig}", headers={"X-MBX-APIKEY": conn.api_key})
                if r.status_code == 200:
                    for trade in r.json():
                        trade["_pair"] = symbol
                        all_trades.append(trade)
            except Exception as e:
                errors.append(f"Failed to fetch {symbol}: {e}")

    # Import new trades
    accounts = {a.id: a for a in db.query(models.Account).all()}
    target_account = accounts.get(conn.account_id) if conn.account_id else None

    for trade in all_trades:
        ext_id = f"binance:{trade['id']}"
        if db.query(models.TransactionEvent).filter(models.TransactionEvent.external_id == ext_id).first():
            skipped += 1
            continue

        try:
            pair = trade["_pair"]
            qty = float(trade["qty"])
            price = float(trade["price"])
            is_buyer = trade["isBuyer"]
            commission = float(trade["commission"])
            commission_asset = trade["commissionAsset"].upper()
            trade_date = datetime.fromtimestamp(trade["time"] / 1000, tz=timezone.utc).strftime("%Y-%m-%d")

            # Determine base/quote assets from pair
            base_sym = pair[:-len(next(q for q in ["USDT","BUSD","BTC","ETH","BNB","EUR","USD"] if pair.endswith(q)))]
            quote_sym = pair[len(base_sym):]

            base_asset = db.query(models.Asset).filter(models.Asset.symbol == base_sym).first()
            quote_asset = db.query(models.Asset).filter(models.Asset.symbol == quote_sym).first()

            if not base_asset or not target_account:
                skipped += 1
                continue

            cost_total = qty * price
            legs = []

            if is_buyer:
                # Bought base_sym, spent quote_sym
                legs.append({"account_id": target_account.id, "asset_id": base_asset.id,
                             "quantity": qty, "unit_price": price, "fee_flag": "false"})
                if quote_asset:
                    legs.append({"account_id": target_account.id, "asset_id": quote_asset.id,
                                "quantity": -cost_total, "unit_price": None, "fee_flag": "false"})
            else:
                # Sold base_sym, received quote_sym
                legs.append({"account_id": target_account.id, "asset_id": base_asset.id,
                             "quantity": -qty, "unit_price": price, "fee_flag": "false"})
                if quote_asset:
                    legs.append({"account_id": target_account.id, "asset_id": quote_asset.id,
                                "quantity": cost_total, "unit_price": None, "fee_flag": "false"})

            # Fee leg
            if commission > 0:
                fee_asset = db.query(models.Asset).filter(models.Asset.symbol == commission_asset).first()
                if fee_asset:
                    legs.append({"account_id": target_account.id, "asset_id": fee_asset.id,
                                "quantity": -commission, "unit_price": None, "fee_flag": "true"})

            event = models.TransactionEvent(
                id=str(uuid4()),
                event_type="trade",
                description=f"{'Buy' if is_buyer else 'Sell'} {base_sym}/{quote_sym}",
                date=trade_date,
                source="api",
                external_id=ext_id,
            )
            db.add(event); db.flush()

            for leg_data in legs:
                holding = db.query(models.Holding).filter(
                    models.Holding.account_id == leg_data["account_id"],
                    models.Holding.asset_id == leg_data["asset_id"]).first()
                if not holding:
                    holding = models.Holding(id=str(uuid4()), account_id=leg_data["account_id"],
                                            asset_id=leg_data["asset_id"], quantity=0.0, avg_cost=0.0)
                    db.add(holding); db.flush()
                old_qty = holding.quantity
                new_qty = old_qty + leg_data["quantity"]
                if leg_data["quantity"] > 0 and leg_data.get("unit_price"):
                    holding.avg_cost = (old_qty * holding.avg_cost + leg_data["quantity"] * leg_data["unit_price"]) / max(new_qty, 0.0001)
                holding.quantity = max(new_qty, 0.0)
                if holding.quantity == 0:
                    db.delete(holding)

                db.add(models.TransactionLeg(
                    id=str(uuid4()), event_id=event.id,
                    account_id=leg_data["account_id"], asset_id=leg_data["asset_id"],
                    quantity=leg_data["quantity"], unit_price=leg_data.get("unit_price"),
                    fee_flag=leg_data["fee_flag"],
                ))

            db.commit()
            imported += 1
        except Exception as e:
            db.rollback()
            errors.append(f"Trade import error: {e}")

    return SyncResult(imported=imported, skipped=skipped, errors=errors[:10], status="active" if not errors else "error")


def _sync_kraken(conn: models.ExchangeConnection, db: Session) -> SyncResult:
    """Fetch trade history from Kraken."""
    imported, skipped, errors = 0, 0, []
    base_url = "https://api.kraken.com"

    def kraken_request(path: str, data: dict) -> dict:
        nonce = str(int(time.time() * 1000))
        data["nonce"] = nonce
        post_data = urllib.parse.urlencode(data)
        encoded = (nonce + post_data).encode()
        message = path.encode() + hashlib.sha256(encoded).digest()
        sig = base64.b64encode(_hmac_sha512(conn.api_secret, message)).decode()
        with httpx.Client(timeout=10.0) as c:
            r = c.post(f"{base_url}{path}", data=data,
                      headers={"API-Key": conn.api_key, "API-Sign": sig})
            r.raise_for_status()
            result = r.json()
            if result.get("error"):
                raise Exception(str(result["error"]))
            return result["result"]

    try:
        trades_result = kraken_request("/0/private/TradesHistory", {"trades": True})
    except Exception as e:
        return SyncResult(imported=0, skipped=0, errors=[f"Kraken auth failed: {e}"], status="error")

    accounts = {a.id: a for a in db.query(models.Account).all()}
    target_account = accounts.get(conn.account_id) if conn.account_id else None
    if not target_account:
        return SyncResult(imported=0, skipped=0, errors=["No linked account"], status="error")

    for trade_id, trade in trades_result.get("trades", {}).items():
        ext_id = f"kraken:{trade_id}"
        if db.query(models.TransactionEvent).filter(models.TransactionEvent.external_id == ext_id).first():
            skipped += 1
            continue

        try:
            pair = trade["pair"]
            # Strip Kraken prefixes (X/Z) for major assets
            clean = lambda s: s[1:] if s.startswith(("X","Z")) and len(s) == 4 else s
            # Kraken pairs like "XXBTZUSD" → base="XBT"→"BTC", quote="USD"
            sym_map = {"XBT": "BTC", "XDG": "DOGE", "XXBT": "BTC"}
            raw_base = pair[:4] if len(pair) >= 6 else pair[:3]
            raw_quote = pair[len(raw_base):]
            base_sym = sym_map.get(raw_base.upper(), clean(raw_base).upper())
            quote_sym = sym_map.get(raw_quote.upper(), clean(raw_quote).upper())

            qty = float(trade["vol"])
            price = float(trade["price"])
            order_type = trade["type"]  # buy/sell
            fee = float(trade.get("fee", 0))
            trade_date = datetime.fromtimestamp(float(trade["time"]), tz=timezone.utc).strftime("%Y-%m-%d")

            base_asset = db.query(models.Asset).filter(models.Asset.symbol == base_sym).first()
            quote_asset = db.query(models.Asset).filter(models.Asset.symbol == quote_sym).first()
            if not base_asset:
                skipped += 1
                continue

            cost_total = qty * price
            legs_data = []
            is_buy = order_type == "buy"

            if is_buy:
                legs_data.append({"account_id": target_account.id, "asset_id": base_asset.id,
                                  "quantity": qty, "unit_price": price, "fee_flag": "false"})
                if quote_asset:
                    legs_data.append({"account_id": target_account.id, "asset_id": quote_asset.id,
                                     "quantity": -cost_total, "unit_price": None, "fee_flag": "false"})
            else:
                legs_data.append({"account_id": target_account.id, "asset_id": base_asset.id,
                                  "quantity": -qty, "unit_price": price, "fee_flag": "false"})
                if quote_asset:
                    legs_data.append({"account_id": target_account.id, "asset_id": quote_asset.id,
                                     "quantity": cost_total, "unit_price": None, "fee_flag": "false"})

            if fee > 0 and quote_asset:
                legs_data.append({"account_id": target_account.id, "asset_id": quote_asset.id,
                                 "quantity": -fee, "unit_price": None, "fee_flag": "true"})

            event = models.TransactionEvent(
                id=str(uuid4()), event_type="trade",
                description=f"{'Buy' if is_buy else 'Sell'} {base_sym}/{quote_sym}",
                date=trade_date, source="api", external_id=ext_id,
            )
            db.add(event); db.flush()
            _apply_legs(legs_data, event.id, db)
            db.commit()
            imported += 1
        except Exception as e:
            db.rollback()
            errors.append(str(e))

    return SyncResult(imported=imported, skipped=skipped, errors=errors[:10],
                      status="active" if not errors else "error")


def _sync_coinbase(conn: models.ExchangeConnection, db: Session) -> SyncResult:
    """Sync Coinbase Advanced Trade."""
    imported, skipped, errors = 0, 0, []
    base_url = "https://api.coinbase.com"

    def cb_headers(method: str, path: str, body: str = "") -> dict:
        ts = str(int(time.time()))
        msg = ts + method.upper() + path + body
        sig = hmac.new(conn.api_secret.encode(), msg.encode(), hashlib.sha256).hexdigest()
        return {"CB-ACCESS-KEY": conn.api_key, "CB-ACCESS-SIGN": sig,
                "CB-ACCESS-TIMESTAMP": ts, "Content-Type": "application/json"}

    accounts_map = {a.id: a for a in db.query(models.Account).all()}
    target_account = accounts_map.get(conn.account_id) if conn.account_id else None
    if not target_account:
        return SyncResult(imported=0, skipped=0, errors=["No linked account"], status="error")

    try:
        path = "/api/v3/brokerage/orders/historical/fills?limit=250"
        with httpx.Client(timeout=10.0) as c:
            r = c.get(f"{base_url}{path}", headers=cb_headers("GET", path))
            r.raise_for_status()
            fills = r.json().get("fills", [])
    except Exception as e:
        return SyncResult(imported=0, skipped=0, errors=[f"Coinbase auth failed: {e}"], status="error")

    for fill in fills:
        ext_id = f"coinbase:{fill.get('trade_id','')}"
        if db.query(models.TransactionEvent).filter(models.TransactionEvent.external_id == ext_id).first():
            skipped += 1
            continue

        try:
            product_id = fill.get("product_id", "")  # e.g. "BTC-USD"
            parts = product_id.split("-")
            if len(parts) < 2:
                skipped += 1
                continue
            base_sym, quote_sym = parts[0].upper(), parts[1].upper()
            qty = float(fill.get("size", 0))
            price = float(fill.get("price", 0))
            side = fill.get("side", "BUY")
            trade_date = fill.get("trade_time", "")[:10]

            base_asset = db.query(models.Asset).filter(models.Asset.symbol == base_sym).first()
            quote_asset = db.query(models.Asset).filter(models.Asset.symbol == quote_sym).first()
            if not base_asset:
                skipped += 1
                continue

            is_buy = side == "BUY"
            cost_total = qty * price
            legs_data = []

            if is_buy:
                legs_data.append({"account_id": target_account.id, "asset_id": base_asset.id,
                                  "quantity": qty, "unit_price": price, "fee_flag": "false"})
                if quote_asset:
                    legs_data.append({"account_id": target_account.id, "asset_id": quote_asset.id,
                                     "quantity": -cost_total, "unit_price": None, "fee_flag": "false"})
            else:
                legs_data.append({"account_id": target_account.id, "asset_id": base_asset.id,
                                  "quantity": -qty, "unit_price": price, "fee_flag": "false"})
                if quote_asset:
                    legs_data.append({"account_id": target_account.id, "asset_id": quote_asset.id,
                                     "quantity": cost_total, "unit_price": None, "fee_flag": "false"})

            commission = float(fill.get("commission", 0))
            if commission > 0 and quote_asset:
                legs_data.append({"account_id": target_account.id, "asset_id": quote_asset.id,
                                 "quantity": -commission, "unit_price": None, "fee_flag": "true"})

            event = models.TransactionEvent(
                id=str(uuid4()), event_type="trade",
                description=f"{'Buy' if is_buy else 'Sell'} {base_sym}/{quote_sym}",
                date=trade_date, source="api", external_id=ext_id,
            )
            db.add(event); db.flush()
            _apply_legs(legs_data, event.id, db)
            db.commit()
            imported += 1
        except Exception as e:
            db.rollback()
            errors.append(str(e))

    return SyncResult(imported=imported, skipped=skipped, errors=errors[:10],
                      status="active" if not errors else "error")


def _sync_bybit(conn: models.ExchangeConnection, db: Session) -> SyncResult:
    """Sync Bybit trade history."""
    imported, skipped, errors = 0, 0, []
    base_url = "https://api.bybit.com"

    def bybit_headers(params: dict) -> dict:
        ts = str(_ms_timestamp())
        recv_window = "5000"
        param_str = "&".join(f"{k}={v}" for k, v in sorted(params.items()))
        pre_sign = ts + conn.api_key + recv_window + param_str
        sig = hmac.new(conn.api_secret.encode(), pre_sign.encode(), hashlib.sha256).hexdigest()
        return {
            "X-BAPI-API-KEY": conn.api_key,
            "X-BAPI-SIGN": sig,
            "X-BAPI-TIMESTAMP": ts,
            "X-BAPI-RECV-WINDOW": recv_window,
        }

    accounts_map = {a.id: a for a in db.query(models.Account).all()}
    target_account = accounts_map.get(conn.account_id) if conn.account_id else None
    if not target_account:
        return SyncResult(imported=0, skipped=0, errors=["No linked account"], status="error")

    try:
        params = {"category": "spot", "limit": "200"}
        with httpx.Client(timeout=10.0) as c:
            r = c.get(f"{base_url}/v5/execution/list", params=params,
                     headers=bybit_headers(params))
            r.raise_for_status()
            data = r.json()
            if data.get("retCode") != 0:
                raise Exception(data.get("retMsg", "Bybit error"))
            trades = data.get("result", {}).get("list", [])
    except Exception as e:
        return SyncResult(imported=0, skipped=0, errors=[f"Bybit auth failed: {e}"], status="error")

    for trade in trades:
        ext_id = f"bybit:{trade.get('execId','')}"
        if db.query(models.TransactionEvent).filter(models.TransactionEvent.external_id == ext_id).first():
            skipped += 1
            continue

        try:
            symbol = trade.get("symbol", "")  # e.g. "BTCUSDT"
            # Common quote assets
            for q in ["USDT", "USDC", "BTC", "ETH", "BNB"]:
                if symbol.endswith(q):
                    base_sym = symbol[:-len(q)]
                    quote_sym = q
                    break
            else:
                skipped += 1
                continue

            qty = float(trade.get("execQty", 0))
            price = float(trade.get("execPrice", 0))
            side = trade.get("side", "Buy")
            exec_fee = float(trade.get("execFee", 0))
            ts_ms = int(trade.get("execTime", 0))
            trade_date = datetime.fromtimestamp(ts_ms / 1000, tz=timezone.utc).strftime("%Y-%m-%d") if ts_ms else datetime.now().strftime("%Y-%m-%d")

            base_asset = db.query(models.Asset).filter(models.Asset.symbol == base_sym).first()
            quote_asset = db.query(models.Asset).filter(models.Asset.symbol == quote_sym).first()
            if not base_asset:
                skipped += 1
                continue

            is_buy = side == "Buy"
            cost_total = qty * price
            legs_data = []

            if is_buy:
                legs_data.append({"account_id": target_account.id, "asset_id": base_asset.id,
                                  "quantity": qty, "unit_price": price, "fee_flag": "false"})
                if quote_asset:
                    legs_data.append({"account_id": target_account.id, "asset_id": quote_asset.id,
                                     "quantity": -cost_total, "unit_price": None, "fee_flag": "false"})
            else:
                legs_data.append({"account_id": target_account.id, "asset_id": base_asset.id,
                                  "quantity": -qty, "unit_price": price, "fee_flag": "false"})
                if quote_asset:
                    legs_data.append({"account_id": target_account.id, "asset_id": quote_asset.id,
                                     "quantity": cost_total, "unit_price": None, "fee_flag": "false"})

            if exec_fee > 0 and quote_asset:
                legs_data.append({"account_id": target_account.id, "asset_id": quote_asset.id,
                                 "quantity": -exec_fee, "unit_price": None, "fee_flag": "true"})

            event = models.TransactionEvent(
                id=str(uuid4()), event_type="trade",
                description=f"{'Buy' if is_buy else 'Sell'} {base_sym}/{quote_sym}",
                date=trade_date, source="api", external_id=ext_id,
            )
            db.add(event); db.flush()
            _apply_legs(legs_data, event.id, db)
            db.commit()
            imported += 1
        except Exception as e:
            db.rollback()
            errors.append(str(e))

    return SyncResult(imported=imported, skipped=skipped, errors=errors[:10],
                      status="active" if not errors else "error")


def _sync_kucoin(conn: models.ExchangeConnection, db: Session) -> SyncResult:
    """Sync KuCoin trade fills."""
    imported, skipped, errors = 0, 0, []
    base_url = "https://api.kucoin.com"

    def kc_headers(method: str, path: str, body: str = "") -> dict:
        ts = str(_ms_timestamp())
        pre_sign = ts + method.upper() + path + body
        sig = base64.b64encode(
            hmac.new(conn.api_secret.encode(), pre_sign.encode(), hashlib.sha256).digest()
        ).decode()
        passphrase_sig = base64.b64encode(
            hmac.new(conn.api_secret.encode(),
                    (conn.passphrase or "").encode(), hashlib.sha256).digest()
        ).decode()
        return {
            "KC-API-KEY": conn.api_key,
            "KC-API-SIGN": sig,
            "KC-API-TIMESTAMP": ts,
            "KC-API-PASSPHRASE": passphrase_sig,
            "KC-API-KEY-VERSION": "2",
            "Content-Type": "application/json",
        }

    accounts_map = {a.id: a for a in db.query(models.Account).all()}
    target_account = accounts_map.get(conn.account_id) if conn.account_id else None
    if not target_account:
        return SyncResult(imported=0, skipped=0, errors=["No linked account"], status="error")

    try:
        path = "/api/v1/fills?pageSize=500"
        with httpx.Client(timeout=10.0) as c:
            r = c.get(f"{base_url}{path}", headers=kc_headers("GET", path))
            r.raise_for_status()
            data = r.json()
            if data.get("code") != "200000":
                raise Exception(data.get("msg", "KuCoin error"))
            items = data.get("data", {}).get("items", [])
    except Exception as e:
        return SyncResult(imported=0, skipped=0, errors=[f"KuCoin auth failed: {e}"], status="error")

    for fill in items:
        ext_id = f"kucoin:{fill.get('tradeId','')}"
        if db.query(models.TransactionEvent).filter(models.TransactionEvent.external_id == ext_id).first():
            skipped += 1
            continue

        try:
            symbol = fill.get("symbol", "")  # e.g. "BTC-USDT"
            parts = symbol.split("-")
            if len(parts) < 2:
                skipped += 1
                continue
            base_sym, quote_sym = parts[0].upper(), parts[1].upper()
            qty = float(fill.get("size", 0))
            price = float(fill.get("price", 0))
            side = fill.get("side", "buy")
            fee = float(fill.get("fee", 0))
            fee_currency = fill.get("feeCurrency", quote_sym).upper()
            ts_ms = int(fill.get("createdAt", 0))
            trade_date = datetime.fromtimestamp(ts_ms / 1000, tz=timezone.utc).strftime("%Y-%m-%d") if ts_ms else datetime.now().strftime("%Y-%m-%d")

            base_asset = db.query(models.Asset).filter(models.Asset.symbol == base_sym).first()
            quote_asset = db.query(models.Asset).filter(models.Asset.symbol == quote_sym).first()
            fee_asset = db.query(models.Asset).filter(models.Asset.symbol == fee_currency).first()
            if not base_asset:
                skipped += 1
                continue

            is_buy = side == "buy"
            cost_total = qty * price
            legs_data = []

            if is_buy:
                legs_data.append({"account_id": target_account.id, "asset_id": base_asset.id,
                                  "quantity": qty, "unit_price": price, "fee_flag": "false"})
                if quote_asset:
                    legs_data.append({"account_id": target_account.id, "asset_id": quote_asset.id,
                                     "quantity": -cost_total, "unit_price": None, "fee_flag": "false"})
            else:
                legs_data.append({"account_id": target_account.id, "asset_id": base_asset.id,
                                  "quantity": -qty, "unit_price": price, "fee_flag": "false"})
                if quote_asset:
                    legs_data.append({"account_id": target_account.id, "asset_id": quote_asset.id,
                                     "quantity": cost_total, "unit_price": None, "fee_flag": "false"})

            if fee > 0 and fee_asset:
                legs_data.append({"account_id": target_account.id, "asset_id": fee_asset.id,
                                 "quantity": -fee, "unit_price": None, "fee_flag": "true"})

            event = models.TransactionEvent(
                id=str(uuid4()), event_type="trade",
                description=f"{'Buy' if is_buy else 'Sell'} {base_sym}/{quote_sym}",
                date=trade_date, source="api", external_id=ext_id,
            )
            db.add(event); db.flush()
            _apply_legs(legs_data, event.id, db)
            db.commit()
            imported += 1
        except Exception as e:
            db.rollback()
            errors.append(str(e))

    return SyncResult(imported=imported, skipped=skipped, errors=errors[:10],
                      status="active" if not errors else "error")


def _sync_okx(conn: models.ExchangeConnection, db: Session) -> SyncResult:
    """Sync OKX trade fills."""
    imported, skipped, errors = 0, 0, []
    base_url = "https://www.okx.com"

    def okx_headers(method: str, path: str, body: str = "") -> dict:
        ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
        pre_sign = ts + method.upper() + path + body
        sig = base64.b64encode(
            hmac.new(conn.api_secret.encode(), pre_sign.encode(), hashlib.sha256).digest()
        ).decode()
        passphrase_b64 = base64.b64encode(
            hmac.new(conn.api_secret.encode(),
                    (conn.passphrase or "").encode(), hashlib.sha256).digest()
        ).decode()
        return {
            "OK-ACCESS-KEY": conn.api_key,
            "OK-ACCESS-SIGN": sig,
            "OK-ACCESS-TIMESTAMP": ts,
            "OK-ACCESS-PASSPHRASE": conn.passphrase or "",
            "Content-Type": "application/json",
        }

    accounts_map = {a.id: a for a in db.query(models.Account).all()}
    target_account = accounts_map.get(conn.account_id) if conn.account_id else None
    if not target_account:
        return SyncResult(imported=0, skipped=0, errors=["No linked account"], status="error")

    try:
        path = "/api/v5/trade/fills?instType=SPOT&limit=100"
        with httpx.Client(timeout=10.0) as c:
            r = c.get(f"{base_url}{path}", headers=okx_headers("GET", path))
            r.raise_for_status()
            data = r.json()
            if data.get("code") != "0":
                raise Exception(data.get("msg", "OKX error"))
            fills = data.get("data", [])
    except Exception as e:
        return SyncResult(imported=0, skipped=0, errors=[f"OKX auth failed: {e}"], status="error")

    for fill in fills:
        ext_id = f"okx:{fill.get('tradeId','')}"
        if db.query(models.TransactionEvent).filter(models.TransactionEvent.external_id == ext_id).first():
            skipped += 1
            continue

        try:
            inst_id = fill.get("instId", "")  # e.g. "BTC-USDT"
            parts = inst_id.split("-")
            if len(parts) < 2:
                skipped += 1
                continue
            base_sym, quote_sym = parts[0].upper(), parts[1].upper()
            qty = float(fill.get("fillSz", 0))
            price = float(fill.get("fillPx", 0))
            side = fill.get("side", "buy")
            fee = abs(float(fill.get("fee", 0)))
            fee_currency = fill.get("feeCcy", quote_sym).upper()
            ts_ms = int(fill.get("ts", 0))
            trade_date = datetime.fromtimestamp(ts_ms / 1000, tz=timezone.utc).strftime("%Y-%m-%d") if ts_ms else datetime.now().strftime("%Y-%m-%d")

            base_asset = db.query(models.Asset).filter(models.Asset.symbol == base_sym).first()
            quote_asset = db.query(models.Asset).filter(models.Asset.symbol == quote_sym).first()
            fee_asset = db.query(models.Asset).filter(models.Asset.symbol == fee_currency).first()
            if not base_asset:
                skipped += 1
                continue

            is_buy = side == "buy"
            cost_total = qty * price
            legs_data = []

            if is_buy:
                legs_data.append({"account_id": target_account.id, "asset_id": base_asset.id,
                                  "quantity": qty, "unit_price": price, "fee_flag": "false"})
                if quote_asset:
                    legs_data.append({"account_id": target_account.id, "asset_id": quote_asset.id,
                                     "quantity": -cost_total, "unit_price": None, "fee_flag": "false"})
            else:
                legs_data.append({"account_id": target_account.id, "asset_id": base_asset.id,
                                  "quantity": -qty, "unit_price": price, "fee_flag": "false"})
                if quote_asset:
                    legs_data.append({"account_id": target_account.id, "asset_id": quote_asset.id,
                                     "quantity": cost_total, "unit_price": None, "fee_flag": "false"})

            if fee > 0 and fee_asset:
                legs_data.append({"account_id": target_account.id, "asset_id": fee_asset.id,
                                 "quantity": -fee, "unit_price": None, "fee_flag": "true"})

            event = models.TransactionEvent(
                id=str(uuid4()), event_type="trade",
                description=f"{'Buy' if is_buy else 'Sell'} {base_sym}/{quote_sym}",
                date=trade_date, source="api", external_id=ext_id,
            )
            db.add(event); db.flush()
            _apply_legs(legs_data, event.id, db)
            db.commit()
            imported += 1
        except Exception as e:
            db.rollback()
            errors.append(str(e))

    return SyncResult(imported=imported, skipped=skipped, errors=errors[:10],
                      status="active" if not errors else "error")


def _apply_legs(legs_data: list, event_id: str, db: Session):
    """Apply transaction legs and update holdings."""
    for leg_data in legs_data:
        holding = db.query(models.Holding).filter(
            models.Holding.account_id == leg_data["account_id"],
            models.Holding.asset_id == leg_data["asset_id"]).first()
        if not holding:
            holding = models.Holding(id=str(uuid4()),
                                    account_id=leg_data["account_id"],
                                    asset_id=leg_data["asset_id"],
                                    quantity=0.0, avg_cost=0.0)
            db.add(holding); db.flush()

        old_qty = holding.quantity
        new_qty = old_qty + leg_data["quantity"]
        if leg_data["quantity"] > 0 and leg_data.get("unit_price"):
            ev = old_qty * holding.avg_cost + leg_data["quantity"] * leg_data["unit_price"]
            holding.avg_cost = ev / max(new_qty, 0.0001)
        holding.quantity = max(new_qty, 0.0)
        if holding.quantity == 0:
            db.delete(holding)

        db.add(models.TransactionLeg(
            id=str(uuid4()), event_id=event_id,
            account_id=leg_data["account_id"],
            asset_id=leg_data["asset_id"],
            quantity=leg_data["quantity"],
            unit_price=leg_data.get("unit_price"),
            fee_flag=leg_data.get("fee_flag", "false"),
        ))


SYNC_FUNCTIONS = {
    "binance": _sync_binance,
    "kraken":  _sync_kraken,
    "coinbase": _sync_coinbase,
    "bybit":   _sync_bybit,
    "kucoin":  _sync_kucoin,
    "okx":     _sync_okx,
}

# ─────────────────────────────────────────────
# RECURRING TRANSACTION HELPER
# ─────────────────────────────────────────────

def _advance_date(date_str: str, frequency: str) -> str:
    """Compute next run date from current date and frequency."""
    try:
        dt = datetime.strptime(date_str, "%Y-%m-%d")
    except Exception:
        return date_str
    if frequency == "daily":
        dt += timedelta(days=1)
    elif frequency == "weekly":
        dt += timedelta(weeks=1)
    elif frequency == "monthly":
        month = dt.month + 1
        year = dt.year + (month - 1) // 12
        month = ((month - 1) % 12) + 1
        day = min(dt.day, [31,28+int((year%4==0 and year%100!=0) or year%400==0),
                            31,30,31,30,31,31,30,31,30,31][month-1])
        dt = dt.replace(year=year, month=month, day=day)
    elif frequency == "quarterly":
        month = dt.month + 3
        year = dt.year + (month - 1) // 12
        month = ((month - 1) % 12) + 1
        day = min(dt.day, [31,28+int((year%4==0 and year%100!=0) or year%400==0),
                            31,30,31,30,31,31,30,31,30,31][month-1])
        dt = dt.replace(year=year, month=month, day=day)
    return dt.strftime("%Y-%m-%d")


# ─────────────────────────────────────────────
# ROUTES
# ─────────────────────────────────────────────
@app.get("/")
def root():
    return {"status": "ok", "message": "LedgerVault API v4.1 — exchange sync enabled"}

@app.post("/reset")
def reset_database():
    Base.metadata.drop_all(bind=engine)
    Base.metadata.create_all(bind=engine)
    return {"status": "ok"}

@app.post("/reset/transactions")
def reset_transactions(db: Session = Depends(get_db)):
    """Delete all transactions, legs, and holdings (keep accounts/assets)."""
    db.query(models.TransactionLeg).delete()
    db.query(models.TransactionEvent).delete()
    db.query(models.Holding).delete()
    db.commit()
    return {"status": "ok", "message": "All transactions and holdings cleared"}

# ── Rates (FX + live crypto) ──────────────────
@app.get("/rates")
def get_rates():
    try:
        fx = _fetch_live_fx()
        fx_source = "live"
    except Exception:
        fx = FALLBACK_FX; fx_source = "fallback"

    crypto_prices = _fetch_crypto_prices()

    prices = {}
    for sym, rate in fx.items():
        prices[sym] = rate if rate else 1.0
    prices.update(crypto_prices)

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
                "symbol": sym, "name": name, "coingecko_id": cg_id,
                "thumb": coin.get("thumb",""),
                "market_cap_rank": coin.get("market_cap_rank"),
                "price_usd": price_usd,
                "asset_class": "crypto", "quote_currency": "USD",
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
                "symbol": sym, "name": name, "exchange": exch,
                "exchange_code": exch_code, "type": qtype,
                "asset_class": "etf" if qtype == "ETF" else "stock",
                "quote_currency": "USD",
            })

        for item in results[:5]:
            info = _fetch_stock_price(item["symbol"])
            if info:
                item["price_usd"]    = info["price"]
                item["change_pct"]   = info["change_pct"]
                item["market_state"] = info["market_state"]
                item["exchange"]     = info.get("exchange", item["exchange"])
                item["name"]         = info.get("name", item["name"])

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

    stock_symbols = {
        assets[h.asset_id].symbol.upper()
        for h in holdings
        if h.asset_id in assets and assets[h.asset_id].asset_class in ("stock", "etf")
    }
    stock_prices: dict[str, float] = {}
    if stock_symbols:
        with ThreadPoolExecutor(max_workers=min(len(stock_symbols), 8)) as pool:
            futures = {pool.submit(_fetch_stock_price, sym): sym for sym in stock_symbols}
            for fut in as_completed(futures):
                sym = futures[fut]
                info = fut.result()
                if info:
                    stock_prices[sym] = info["price"]

    portfolio_items = []
    total_base = cash_total = crypto_total = stock_total = 0.0

    for holding in holdings:
        asset   = assets.get(holding.asset_id)
        account = accounts.get(holding.account_id)
        if not asset or not account: continue

        sym = asset.symbol.upper()

        if asset.asset_class == "fiat":
            price_usd = fx.get(sym, 1.0)
        elif asset.asset_class == "crypto":
            price_usd = crypto_prices.get(sym, 0.0)
        elif asset.asset_class in ("stock","etf"):
            price_usd = stock_prices.get(sym, 0.0)
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
        if asset.asset_class == "fiat":           cash_total   += value_base
        elif asset.asset_class == "crypto":        crypto_total += value_base
        elif asset.asset_class in ("stock","etf"): stock_total  += value_base

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
            {"id": e.id, "event_type": e.event_type, "category": e.category,
             "description": e.description, "date": e.date, "note": e.note}
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

@app.get("/accounts/{account_id}/holdings", response_model=HoldingList)
def list_account_holdings(account_id: str, db: Session = Depends(get_db)):
    account = db.query(models.Account).filter(models.Account.id == account_id).first()
    if not account:
        raise HTTPException(status_code=404, detail="Account not found")
    return {"items": db.query(models.Holding).filter(models.Holding.account_id == account_id).all()}

@app.get("/accounts/{account_id}/transactions", response_model=TransactionEventList)
def list_account_transactions(account_id: str, db: Session = Depends(get_db)):
    account = db.query(models.Account).filter(models.Account.id == account_id).first()
    if not account:
        raise HTTPException(status_code=404, detail="Account not found")
    ids = [r[0] for r in db.query(models.TransactionLeg.event_id)
           .filter(models.TransactionLeg.account_id == account_id).distinct().all()]
    items = (db.query(models.TransactionEvent)
             .filter(models.TransactionEvent.id.in_(ids))
             .order_by(models.TransactionEvent.date.desc()).all())
    return {"items": items}

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
def list_transaction_events(account_id: str = Query(None), db: Session = Depends(get_db)):
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
                if new_qty <= 0:
                    db.delete(holding)
                else:
                    if leg.quantity > 0 and leg.unit_price is not None:
                        current_value = holding.quantity * holding.avg_cost
                        removed_value = leg.quantity * leg.unit_price
                        holding.avg_cost = (current_value - removed_value) / new_qty
                    holding.quantity = new_qty
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

# ── Exchange Connections ───────────────────────
@app.get("/exchange-connections", response_model=ExchangeConnectionList)
def list_exchange_connections(db: Session = Depends(get_db)):
    items = db.query(models.ExchangeConnection).all()
    result = []
    for c in items:
        masked = ("*" * (len(c.api_key) - 4) + c.api_key[-4:]) if len(c.api_key) >= 4 else "****"
        result.append(ExchangeConnectionOut(
            id=c.id, exchange=c.exchange, name=c.name,
            api_key_masked=masked, account_id=c.account_id,
            last_synced=c.last_synced, status=c.status,
            status_message=c.status_message,
        ))
    return {"items": result}

@app.post("/exchange-connections", response_model=ExchangeConnectionOut)
def create_exchange_connection(payload: ExchangeConnectionCreate, db: Session = Depends(get_db)):
    conn = models.ExchangeConnection(
        id=str(uuid4()), exchange=payload.exchange, name=payload.name,
        api_key=payload.api_key, api_secret=payload.api_secret,
        passphrase=payload.passphrase, account_id=payload.account_id,
        status="active",
    )
    db.add(conn); db.commit(); db.refresh(conn)
    masked = ("*" * (len(conn.api_key) - 4) + conn.api_key[-4:]) if len(conn.api_key) >= 4 else "****"
    return ExchangeConnectionOut(
        id=conn.id, exchange=conn.exchange, name=conn.name,
        api_key_masked=masked, account_id=conn.account_id,
        last_synced=conn.last_synced, status=conn.status,
        status_message=conn.status_message,
    )

@app.delete("/exchange-connections/{connection_id}")
def delete_exchange_connection(connection_id: str, db: Session = Depends(get_db)):
    conn = db.query(models.ExchangeConnection).filter(
        models.ExchangeConnection.id == connection_id).first()
    if not conn:
        raise HTTPException(status_code=404, detail="Connection not found")
    db.delete(conn); db.commit()
    return {"status": "ok"}

@app.post("/exchange-connections/{connection_id}/sync", response_model=SyncResult)
def sync_exchange_connection(connection_id: str, db: Session = Depends(get_db)):
    conn = db.query(models.ExchangeConnection).filter(
        models.ExchangeConnection.id == connection_id).first()
    if not conn:
        raise HTTPException(status_code=404, detail="Connection not found")

    sync_fn = SYNC_FUNCTIONS.get(conn.exchange)
    if not sync_fn:
        raise HTTPException(status_code=400, detail=f"Unsupported exchange: {conn.exchange}")

    result = sync_fn(conn, db)

    # Update connection status
    conn.last_synced = _utc_now_iso()
    conn.status = result.status
    conn.status_message = result.errors[0] if result.errors else None
    db.commit()

    return result

# ── Recurring Transactions ─────────────────────
@app.get("/recurring-transactions", response_model=RecurringTransactionList)
def list_recurring_transactions(db: Session = Depends(get_db)):
    return {"items": db.query(models.RecurringTransaction).all()}

@app.post("/recurring-transactions", response_model=RecurringTransactionOut)
def create_recurring_transaction(payload: RecurringTransactionCreate, db: Session = Depends(get_db)):
    item = models.RecurringTransaction(
        id=str(uuid4()),
        name=payload.name, event_type=payload.event_type,
        category=payload.category, description=payload.description, note=payload.note,
        from_account_id=payload.from_account_id, from_asset_id=payload.from_asset_id,
        from_quantity=payload.from_quantity,
        to_account_id=payload.to_account_id, to_asset_id=payload.to_asset_id,
        to_quantity=payload.to_quantity, unit_price=payload.unit_price,
        frequency=payload.frequency, start_date=payload.start_date,
        next_run_date=payload.next_run_date, enabled=payload.enabled,
    )
    db.add(item); db.commit(); db.refresh(item); return item

@app.put("/recurring-transactions/{rt_id}", response_model=RecurringTransactionOut)
def update_recurring_transaction(rt_id: str, payload: RecurringTransactionUpdate,
                                  db: Session = Depends(get_db)):
    item = db.query(models.RecurringTransaction).filter(
        models.RecurringTransaction.id == rt_id).first()
    if not item:
        raise HTTPException(status_code=404, detail="Not found")
    for field, value in payload.dict(exclude_none=True).items():
        setattr(item, field, value)
    db.commit(); db.refresh(item); return item

@app.delete("/recurring-transactions/{rt_id}")
def delete_recurring_transaction(rt_id: str, db: Session = Depends(get_db)):
    item = db.query(models.RecurringTransaction).filter(
        models.RecurringTransaction.id == rt_id).first()
    if not item:
        raise HTTPException(status_code=404, detail="Not found")
    db.delete(item); db.commit()
    return {"status": "ok"}

@app.post("/recurring-transactions/{rt_id}/execute")
def execute_recurring_transaction(rt_id: str, db: Session = Depends(get_db)):
    """Manually execute a recurring transaction now."""
    item = db.query(models.RecurringTransaction).filter(
        models.RecurringTransaction.id == rt_id).first()
    if not item:
        raise HTTPException(status_code=404, detail="Not found")

    today = datetime.now().strftime("%Y-%m-%d")
    from_account = db.query(models.Account).filter(models.Account.id == item.from_account_id).first()
    if not from_account:
        raise HTTPException(status_code=404, detail="Source account not found")

    legs_data = []
    from_asset = _resolve_asset(item.from_asset_id or "", from_account, db)
    legs_data.append({
        "account_id": item.from_account_id, "asset_id": from_asset.id,
        "quantity": -item.from_quantity, "unit_price": item.unit_price, "fee_flag": "false"
    })

    if item.to_account_id and item.to_quantity:
        to_account = db.query(models.Account).filter(models.Account.id == item.to_account_id).first()
        if to_account:
            to_asset = _resolve_asset(item.to_asset_id or "", to_account, db)
            legs_data.append({
                "account_id": item.to_account_id, "asset_id": to_asset.id,
                "quantity": item.to_quantity, "unit_price": item.unit_price, "fee_flag": "false"
            })

    event = models.TransactionEvent(
        id=str(uuid4()), event_type=item.event_type,
        category=item.category, description=item.description or item.name,
        date=today, note=item.note, source="recurring",
        external_id=f"recurring:{item.id}:{today}",
    )
    db.add(event); db.flush()
    _apply_legs(legs_data, event.id, db)

    item.last_run_date = today
    item.next_run_date = _advance_date(today, item.frequency)
    db.commit()

    return {"status": "ok", "event_id": event.id, "next_run_date": item.next_run_date}

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


# ─────────────────────────────────────────────────────────────────────────────
# TrueLayer Open Banking
# ─────────────────────────────────────────────────────────────────────────────

TRUELAYER_CLIENT_ID     = os.getenv("TRUELAYER_CLIENT_ID",     "sandbox-ledgervault-0a1cb9")
TRUELAYER_CLIENT_SECRET = os.getenv("TRUELAYER_CLIENT_SECRET", "c6f044fb-1437-467c-9635-710518ac8957")
TRUELAYER_REDIRECT_URI  = os.getenv("TRUELAYER_REDIRECT_URI",  "ledgervault://truelayer/callback")
TRUELAYER_AUTH_URL      = "https://auth.truelayer-sandbox.com"
TRUELAYER_API_URL       = "https://api.truelayer-sandbox.com"


def _tl_conn_out(c: models.BankConnection) -> dict:
    return {
        "id": c.id,
        "provider_id": c.provider_id,
        "provider_name": c.provider_name,
        "account_display_name": c.account_display_name,
        "account_type": c.account_type,
        "currency": c.currency,
        "truelayer_account_id": c.truelayer_account_id,
        "ledger_account_id": c.ledger_account_id,
        "last_synced": c.last_synced,
        "status": c.status,
        "status_message": c.status_message,
    }


def _tl_fresh_token(conn: models.BankConnection, db: Session) -> str:
    """Return a valid access token, refreshing via refresh_token if needed."""
    if not conn.refresh_token:
        return conn.access_token
    try:
        with httpx.Client(timeout=10) as c:
            r = c.post(f"{TRUELAYER_AUTH_URL}/connect/token", data={
                "grant_type":    "refresh_token",
                "client_id":     TRUELAYER_CLIENT_ID,
                "client_secret": TRUELAYER_CLIENT_SECRET,
                "refresh_token": conn.refresh_token,
            })
            if r.status_code == 200:
                tokens = r.json()
                conn.access_token  = tokens["access_token"]
                conn.refresh_token = tokens.get("refresh_token", conn.refresh_token)
                db.commit()
                return conn.access_token
    except Exception:
        pass
    return conn.access_token


@app.get("/bank-connections/auth-url", response_model=BankAuthUrlResponse)
def bank_auth_url():
    """Generate a TrueLayer OAuth URL for the iOS app to open."""
    import secrets
    state  = secrets.token_urlsafe(16)
    params = {
        "response_type": "code",
        "client_id":     TRUELAYER_CLIENT_ID,
        "scope":         "info accounts balance transactions",
        "redirect_uri":  TRUELAYER_REDIRECT_URI,
        "state":         state,
        "enable_mock":   "true",
        "providers":     "uk-ob-all uk-oauth-all",
    }
    url = f"{TRUELAYER_AUTH_URL}/?{urllib.parse.urlencode(params)}"
    return {"auth_url": url, "state": state}


@app.post("/bank-connections/callback", response_model=BankCallbackResponse)
def bank_callback(code: str = Query(...), db: Session = Depends(get_db)):
    """Exchange OAuth code for tokens; fetch & persist TrueLayer accounts."""
    # 1. Exchange code for tokens
    with httpx.Client(timeout=10) as c:
        r = c.post(f"{TRUELAYER_AUTH_URL}/connect/token", data={
            "grant_type":    "authorization_code",
            "client_id":     TRUELAYER_CLIENT_ID,
            "client_secret": TRUELAYER_CLIENT_SECRET,
            "redirect_uri":  TRUELAYER_REDIRECT_URI,
            "code":          code,
        })
        if r.status_code != 200:
            raise HTTPException(400, f"Token exchange failed: {r.text[:200]}")
        tokens        = r.json()
        access_token  = tokens["access_token"]
        refresh_token = tokens.get("refresh_token", "")

    # 2. Fetch accounts from TrueLayer
    with httpx.Client(timeout=10) as c:
        r = c.get(f"{TRUELAYER_API_URL}/data/v1/accounts",
                  headers={"Authorization": f"Bearer {access_token}"})
        if r.status_code != 200:
            raise HTTPException(400, f"Failed to fetch accounts: {r.text[:200]}")
        tl_accounts = r.json().get("results", [])

    # 3. Create/update BankConnection rows (one per TrueLayer account)
    created = []
    for tl_acct in tl_accounts:
        tl_id         = tl_acct["account_id"]
        provider      = tl_acct.get("provider", {})
        provider_id   = provider.get("provider_id", "unknown")
        provider_name = provider.get("display_name", "Bank")

        existing = db.query(models.BankConnection).filter_by(truelayer_account_id=tl_id).first()
        if existing:
            # Refresh tokens for existing connection
            existing.access_token  = access_token
            existing.refresh_token = refresh_token
            existing.status        = "active"
            created.append(existing)
            continue

        conn = models.BankConnection(
            id=str(uuid4()),
            provider_id=provider_id,
            provider_name=provider_name,
            account_display_name=tl_acct.get("display_name", "Account"),
            account_type=tl_acct.get("account_type", "TRANSACTION"),
            currency=tl_acct.get("currency", "GBP"),
            truelayer_account_id=tl_id,
            access_token=access_token,
            refresh_token=refresh_token,
            status="active",
        )
        db.add(conn)
        created.append(conn)

    db.commit()
    return {"items": [_tl_conn_out(c) for c in created]}


@app.get("/bank-connections", response_model=BankConnectionList)
def list_bank_connections(db: Session = Depends(get_db)):
    conns = db.query(models.BankConnection).all()
    return {"items": [_tl_conn_out(c) for c in conns]}


@app.delete("/bank-connections/{conn_id}")
def delete_bank_connection(conn_id: str, db: Session = Depends(get_db)):
    conn = db.query(models.BankConnection).filter_by(id=conn_id).first()
    if not conn:
        raise HTTPException(404, "Bank connection not found")
    db.delete(conn)
    db.commit()
    return {"ok": True}


@app.put("/bank-connections/{conn_id}/link", response_model=BankConnectionOut)
def link_bank_to_account(conn_id: str, account_id: str = Query(...),
                         db: Session = Depends(get_db)):
    """Link a TrueLayer bank connection to a LedgerVault account for syncing."""
    conn = db.query(models.BankConnection).filter_by(id=conn_id).first()
    if not conn:
        raise HTTPException(404, "Bank connection not found")
    conn.ledger_account_id = account_id
    db.commit()
    return _tl_conn_out(conn)


@app.post("/bank-connections/{conn_id}/sync", response_model=SyncResult)
def sync_bank_connection(conn_id: str, db: Session = Depends(get_db)):
    """Import the last 90 days of transactions from TrueLayer."""
    conn = db.query(models.BankConnection).filter_by(id=conn_id).first()
    if not conn:
        raise HTTPException(404, "Bank connection not found")
    if not conn.ledger_account_id:
        raise HTTPException(400, "Link a LedgerVault account to this connection first.")

    access_token = _tl_fresh_token(conn, db)
    from_date    = (datetime.now(timezone.utc) - timedelta(days=90)).strftime("%Y-%m-%dT%H:%M:%SZ")
    imported = 0; skipped = 0; errors = []

    try:
        with httpx.Client(timeout=20) as c:
            r = c.get(
                f"{TRUELAYER_API_URL}/data/v1/accounts/{conn.truelayer_account_id}/transactions",
                headers={"Authorization": f"Bearer {access_token}"},
                params={"from": from_date},
            )
            if r.status_code != 200:
                conn.status         = "error"
                conn.status_message = f"TrueLayer {r.status_code}: {r.text[:120]}"
                db.commit()
                raise HTTPException(400, conn.status_message)
            transactions = r.json().get("results", [])
    except HTTPException:
        raise
    except Exception as e:
        conn.status = "error"; conn.status_message = str(e)[:120]
        db.commit()
        raise HTTPException(500, str(e))

    # Ensure a fiat Asset row exists for this currency
    currency   = conn.currency or "GBP"
    fiat_asset = db.query(models.Asset).filter_by(symbol=currency).first()
    if not fiat_asset:
        fiat_asset = models.Asset(
            id=str(uuid4()), symbol=currency, name=currency,
            asset_class="fiat", quote_currency="USD")
        db.add(fiat_asset)
        db.flush()

    for tx in transactions:
        tl_tx_id    = tx.get("transaction_id", "")
        external_id = f"truelayer:{conn.id}:{tl_tx_id}"

        if db.query(models.TransactionEvent).filter_by(external_id=external_id).first():
            skipped += 1
            continue

        amount      = float(tx.get("amount", 0))
        description = (tx.get("description") or tx.get("merchant_name") or "Bank Transaction")
        tx_date     = (tx.get("timestamp") or tx.get("normalised_provider_transaction_id", ""))[:10]
        if not tx_date:
            tx_date = datetime.now(timezone.utc).strftime("%Y-%m-%d")

        classifications = tx.get("transaction_classification") or []
        category = classifications[0] if classifications else None

        if amount == 0:
            skipped += 1
            continue

        event_type = "income" if amount > 0 else "expense"
        try:
            event = models.TransactionEvent(
                id=str(uuid4()), event_type=event_type,
                description=description[:200], category=category,
                date=tx_date, source="truelayer", external_id=external_id,
            )
            db.add(event)
            db.flush()

            leg = models.TransactionLeg(
                id=str(uuid4()), event_id=event.id,
                account_id=conn.ledger_account_id,
                asset_id=fiat_asset.id,
                quantity=abs(amount),
                unit_price=1.0, fee_flag="false",
            )
            db.add(leg)
            imported += 1
        except Exception as e:
            errors.append(str(e)[:80])

    conn.last_synced    = datetime.now(timezone.utc).isoformat()
    conn.status         = "active"
    conn.status_message = None
    db.commit()
    return {"imported": imported, "skipped": skipped, "errors": errors, "status": "ok"}
