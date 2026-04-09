from uuid import uuid4
from fastapi import FastAPI, Depends, HTTPException, Query, Header, Request
from typing import Optional
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy.orm import Session
import time, os, httpx, logging, hmac, hashlib, base64, urllib.parse, random, secrets, json
from datetime import datetime, timedelta, timezone
from concurrent.futures import ThreadPoolExecutor, as_completed
import jwt as pyjwt
from passlib.context import CryptContext
from slowapi import Limiter, _rate_limit_exceeded_handler
from slowapi.util import get_remote_address
from slowapi.errors import RateLimitExceeded
from cryptography.fernet import Fernet, InvalidToken
import pyotp
from apscheduler.schedulers.background import BackgroundScheduler

from app.db import engine, SessionLocal, Base
from sqlalchemy import text as _sql_text, func as _sqlfunc
from app import models
from app.schemas import (
    AccountList, AccountOut, AccountCreate, AccountUpdate,
    AssetList, AssetOut, AssetCreate,
    HoldingList,
    TransactionEventList, TransactionEventOut, TransactionEventCreate, TransactionEventUpdate,
    TransactionLegList,
    ExchangeConnectionCreate, ExchangeConnectionOut, ExchangeConnectionList, SyncResult,
    RecurringTransactionCreate, RecurringTransactionUpdate,
    RecurringTransactionOut, RecurringTransactionList,
    BankConnectionOut, BankConnectionList, BankAuthUrlResponse, BankCallbackResponse,
    RegisterRequest, LoginRequest, VerifyEmailRequest, ResendCodeRequest,
    ForgotPasswordRequest, ResetPasswordRequest, SocialAuthRequest, AuthResponse,
    UpdateProfileRequest,
    TotpSetupResponse, TotpVerifyRequest, TotpStatusResponse,
    AccountProfileCreate, AccountProfileUpdate, AccountProfileOut, AccountProfileList,
)

app = FastAPI(title="LedgerVault API", version="4.3.0")
models.Base.metadata.create_all(bind=engine)

# ── Recurring transaction scheduler ──────────────────────────────────────────
def _auto_execute_recurring():
    """Hourly job: execute all enabled recurring transactions that are due."""
    db = SessionLocal()
    try:
        today = datetime.now().strftime("%Y-%m-%d")
        due = db.query(models.RecurringTransaction).filter(
            models.RecurringTransaction.enabled == True,
            models.RecurringTransaction.next_run_date <= today
        ).all()
        for item in due:
            try:
                # Skip if already executed today (idempotency check)
                existing = db.query(models.TransactionEvent).filter(
                    models.TransactionEvent.external_id == f"recurring:{item.id}:{today}"
                ).first()
                if existing:
                    continue
                from_account = db.query(models.Account).filter(
                    models.Account.id == item.from_account_id).first()
                if not from_account:
                    continue
                legs_data = []
                from_asset = _resolve_asset(item.from_asset_id or "", from_account, db)
                legs_data.append({
                    "account_id": item.from_account_id, "asset_id": from_asset.id,
                    "quantity": -item.from_quantity, "unit_price": item.unit_price,
                    "fee_flag": "false"
                })
                if item.to_account_id and item.to_quantity:
                    to_account = db.query(models.Account).filter(
                        models.Account.id == item.to_account_id).first()
                    if to_account:
                        to_asset = _resolve_asset(item.to_asset_id or "", to_account, db)
                        legs_data.append({
                            "account_id": item.to_account_id, "asset_id": to_asset.id,
                            "quantity": item.to_quantity, "unit_price": item.unit_price,
                            "fee_flag": "false"
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
                logger.info(f"Auto-executed recurring transaction {item.id} ({item.name})")
            except Exception as e:
                db.rollback()
                logger.error(f"Failed to auto-execute recurring {item.id}: {e}")
    finally:
        db.close()

_scheduler = BackgroundScheduler()
_scheduler.add_job(_auto_execute_recurring, "interval", hours=1, id="recurring_executor",
                   next_run_time=datetime.now())  # run immediately on startup too
_scheduler.start()

logger = logging.getLogger("ledgervault")

# ── Rate limiter ────────────────────────────────────────────────────────────
limiter = Limiter(key_func=get_remote_address)
app.state.limiter = limiter
app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)

# ── Idempotent schema migrations (add columns safely to existing DB) ──────────
# Each statement runs in its own connection to prevent one failure from
# aborting the rest (PostgreSQL aborts the whole transaction on any error).
for _stmt in [
    "ALTER TABLE accounts ADD COLUMN IF NOT EXISTS user_id VARCHAR",
    "CREATE INDEX IF NOT EXISTS ix_accounts_user_id ON accounts (user_id)",
    "ALTER TABLE bank_connections ADD COLUMN IF NOT EXISTS provider VARCHAR DEFAULT 'truelayer'",
    "ALTER TABLE bank_connections ADD COLUMN IF NOT EXISTS saltedge_connection_id VARCHAR",
    "ALTER TABLE bank_connections ALTER COLUMN saltedge_connection_id DROP NOT NULL",
    "ALTER TABLE users ADD COLUMN IF NOT EXISTS logout_at VARCHAR",
    "ALTER TABLE users ADD COLUMN IF NOT EXISTS totp_secret VARCHAR",
    "ALTER TABLE users ADD COLUMN IF NOT EXISTS totp_enabled BOOLEAN DEFAULT FALSE",
    # New aggregator tables
    """CREATE TABLE IF NOT EXISTS snaptrade_connections (
        id VARCHAR PRIMARY KEY,
        user_id VARCHAR NOT NULL,
        snaptrade_user_id VARCHAR NOT NULL,
        snaptrade_secret VARCHAR NOT NULL,
        brokerage_name VARCHAR,
        brokerage_id VARCHAR,
        authorization_id VARCHAR,
        account_id VARCHAR,
        status VARCHAR NOT NULL DEFAULT 'active',
        status_message VARCHAR,
        last_synced VARCHAR
    )""",
    "CREATE INDEX IF NOT EXISTS ix_snaptrade_connections_user_id ON snaptrade_connections (user_id)",
    """CREATE TABLE IF NOT EXISTS vezgo_connections (
        id VARCHAR PRIMARY KEY,
        user_id VARCHAR NOT NULL,
        vezgo_user_id VARCHAR NOT NULL,
        vezgo_token VARCHAR,
        account_name VARCHAR,
        account_id VARCHAR,
        status VARCHAR NOT NULL DEFAULT 'active',
        status_message VARCHAR,
        last_synced VARCHAR
    )""",
    "CREATE INDEX IF NOT EXISTS ix_vezgo_connections_user_id ON vezgo_connections (user_id)",
    """CREATE TABLE IF NOT EXISTS flanks_connections (
        id VARCHAR PRIMARY KEY,
        user_id VARCHAR NOT NULL,
        broker_id VARCHAR NOT NULL,
        broker_name VARCHAR,
        flanks_user_id VARCHAR,
        account_id VARCHAR,
        status VARCHAR NOT NULL DEFAULT 'active',
        status_message VARCHAR,
        last_synced VARCHAR
    )""",
    "CREATE INDEX IF NOT EXISTS ix_flanks_connections_user_id ON flanks_connections (user_id)",
    """CREATE TABLE IF NOT EXISTS crypto_wallets (
        id VARCHAR PRIMARY KEY,
        user_id VARCHAR NOT NULL,
        chain VARCHAR NOT NULL,
        address VARCHAR NOT NULL,
        label VARCHAR,
        last_synced VARCHAR,
        created_at VARCHAR
    )""",
    "CREATE INDEX IF NOT EXISTS ix_crypto_wallets_user_id ON crypto_wallets (user_id)",
    """CREATE TABLE IF NOT EXISTS watchlist (
        id VARCHAR PRIMARY KEY,
        user_id VARCHAR NOT NULL,
        symbol VARCHAR NOT NULL,
        added_at VARCHAR
    )""",
    "CREATE INDEX IF NOT EXISTS ix_watchlist_user_id ON watchlist (user_id)",
    "CREATE UNIQUE INDEX IF NOT EXISTS ix_watchlist_user_symbol ON watchlist (user_id, symbol)",
    "ALTER TABLE accounts ADD COLUMN IF NOT EXISTS exclude_from_total BOOLEAN NOT NULL DEFAULT FALSE",
    "ALTER TABLE crypto_wallets ADD COLUMN IF NOT EXISTS account_id VARCHAR",
    # Timestamp for transaction events — enables correct newest-first sorting within same date
    "ALTER TABLE transaction_events ADD COLUMN IF NOT EXISTS created_at VARCHAR",
    # Back-fill NULL created_at with the event date so existing rows sort consistently
    "UPDATE transaction_events SET created_at = date WHERE created_at IS NULL",
    # user_id on exchange_connections — isolates each user's API keys
    "ALTER TABLE exchange_connections ADD COLUMN IF NOT EXISTS user_id VARCHAR",
    # user_id on bank_connections — isolates each user's open-banking tokens
    "ALTER TABLE bank_connections ADD COLUMN IF NOT EXISTS user_id VARCHAR",
    # user_id on recurring_transactions — isolates each user's recurring rules
    "ALTER TABLE recurring_transactions ADD COLUMN IF NOT EXISTS user_id VARCHAR",
    # Account profiles — named groups of accounts for filtered portfolio views
    """CREATE TABLE IF NOT EXISTS account_profiles (
        id VARCHAR PRIMARY KEY,
        user_id VARCHAR NOT NULL,
        name VARCHAR NOT NULL,
        emoji VARCHAR,
        account_ids TEXT NOT NULL DEFAULT '[]',
        sort_order VARCHAR,
        created_at VARCHAR
    )""",
    "CREATE INDEX IF NOT EXISTS ix_account_profiles_user_id ON account_profiles (user_id)",
    # APNs device tokens — server-side push notifications
    """CREATE TABLE IF NOT EXISTS device_tokens (
        id VARCHAR PRIMARY KEY,
        user_id VARCHAR NOT NULL,
        token VARCHAR NOT NULL UNIQUE,
        sandbox BOOLEAN NOT NULL DEFAULT FALSE,
        updated_at VARCHAR
    )""",
    "CREATE INDEX IF NOT EXISTS ix_device_tokens_user_id ON device_tokens (user_id)",
]:
    try:
        with engine.connect() as _conn:
            _conn.execute(_sql_text(_stmt))
            _conn.commit()
    except Exception:
        pass  # e.g. ALTER COLUMN is idempotent but has no IF NOT EXISTS

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"], allow_credentials=True,
    allow_methods=["*"], allow_headers=["*"],
)

# ─────────────────────────────────────────────
# AUTH UTILITIES
# ─────────────────────────────────────────────
JWT_SECRET     = os.getenv("JWT_SECRET", "ledgervault-dev-secret-change-in-production")
JWT_ALGORITHM  = "HS256"
JWT_EXPIRE_DAYS = 90
RESEND_API_KEY = os.getenv("RESEND_API_KEY", "")
RESEND_FROM    = os.getenv("RESEND_FROM", "LedgerVault <noreply@ledgervault.app>")

pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")

# ── Encryption at rest ──────────────────────────────────────────────────────
_ENCRYPTION_KEY = os.getenv("ENCRYPTION_KEY", "")
_fernet: Optional[Fernet] = None
if _ENCRYPTION_KEY:
    try:
        _fernet = Fernet(_ENCRYPTION_KEY.encode())
    except Exception:
        logger.warning("Invalid ENCRYPTION_KEY — sensitive data will NOT be encrypted at rest")

def _encrypt(text: str) -> str:
    """Encrypt a string. Returns plaintext unchanged if no key is configured."""
    if not _fernet or not text:
        return text
    return _fernet.encrypt(text.encode()).decode()

def _decrypt(text: str) -> str:
    """Decrypt a Fernet token. Falls back to returning as-is for legacy plaintext data."""
    if not _fernet or not text:
        return text
    try:
        return _fernet.decrypt(text.encode()).decode()
    except (InvalidToken, Exception):
        return text  # already plaintext (pre-encryption legacy row)

def _create_token(user_id: str) -> str:
    now = datetime.now(timezone.utc)
    payload = {
        "sub": user_id,
        "iat": int(now.timestamp()),
        "exp": now + timedelta(days=JWT_EXPIRE_DAYS),
    }
    return pyjwt.encode(payload, JWT_SECRET, algorithm=JWT_ALGORITHM)

def _decode_token(token: str) -> Optional[dict]:
    """Returns the full payload dict, or None if invalid."""
    try:
        return pyjwt.decode(token, JWT_SECRET, algorithms=[JWT_ALGORITHM])
    except Exception:
        return None

def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()

def get_user_id(authorization: Optional[str] = Header(None)) -> Optional[str]:
    """Optional auth — returns user_id or None. Does NOT check revocation (no DB)."""
    if not authorization or not authorization.startswith("Bearer "):
        return None
    data = _decode_token(authorization[7:])
    return data.get("sub") if data else None

def require_user_id(
    authorization: Optional[str] = Header(None),
    db: Session = Depends(get_db),
) -> str:
    """Strict auth — raises 401 if missing, invalid, or revoked."""
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Authentication required")
    data = _decode_token(authorization[7:])
    if not data:
        raise HTTPException(status_code=401, detail="Authentication required")
    uid: Optional[str] = data.get("sub")
    iat: Optional[int] = data.get("iat")
    if not uid:
        raise HTTPException(status_code=401, detail="Authentication required")
    # Check whether this token was issued before the last logout/invalidation
    if iat:
        user = db.query(models.User).filter(models.User.id == uid).first()
        if user and user.logout_at:
            try:
                revoked_ts = datetime.fromisoformat(user.logout_at).timestamp()
                if iat < revoked_ts:
                    raise HTTPException(
                        status_code=401,
                        detail="Session has been revoked. Please sign in again.",
                    )
            except ValueError:
                pass
    return uid

def _gen_otp() -> str:
    return str(random.randint(100000, 999999))

def _otp_expires() -> str:
    return (datetime.now(timezone.utc) + timedelta(minutes=15)).isoformat()

def _otp_valid(expires_str: Optional[str]) -> bool:
    if not expires_str:
        return False
    try:
        exp = datetime.fromisoformat(expires_str)
        if exp.tzinfo is None:
            exp = exp.replace(tzinfo=timezone.utc)
        return datetime.now(timezone.utc) < exp
    except Exception:
        return False

def _send_email(to: str, subject: str, html: str) -> bool:
    if not RESEND_API_KEY:
        logger.warning(f"RESEND_API_KEY not set — skipping email to {to}: {subject}")
        return False
    try:
        with httpx.Client(timeout=10.0) as c:
            r = c.post(
                "https://api.resend.com/emails",
                headers={"Authorization": f"Bearer {RESEND_API_KEY}", "Content-Type": "application/json"},
                json={"from": RESEND_FROM, "to": [to], "subject": subject, "html": html},
            )
            return r.status_code in (200, 201)
    except Exception as e:
        logger.warning(f"Email send failed: {e}")
        return False

# ─────────────────────────────────────────────
# APNs  (Apple Push Notification Service)
# ─────────────────────────────────────────────
APNS_KEY_ID      = os.getenv("APNS_KEY_ID", "")       # 10-char key ID from Apple Developer
APNS_TEAM_ID     = os.getenv("APNS_TEAM_ID", "")      # 10-char team ID
APNS_BUNDLE_ID   = os.getenv("APNS_BUNDLE_ID", "")    # e.g. com.myledgervault.LedgerVault
APNS_KEY_CONTENT = os.getenv("APNS_KEY_CONTENT", "")  # Full PEM; Railway stores \n as literal \n

_apns_jwt_cache: dict = {"token": None, "expires": 0}

def _get_apns_jwt() -> Optional[str]:
    """Return a cached APNs auth JWT (valid 55 min, refreshed automatically)."""
    if not all([APNS_KEY_ID, APNS_TEAM_ID, APNS_KEY_CONTENT]):
        return None
    now = int(time.time())
    if _apns_jwt_cache["token"] and _apns_jwt_cache["expires"] > now + 60:
        return _apns_jwt_cache["token"]
    key_pem = APNS_KEY_CONTENT.replace("\\n", "\n")
    try:
        token = pyjwt.encode(
            {"iss": APNS_TEAM_ID, "iat": now},
            key_pem,
            algorithm="ES256",
            headers={"kid": APNS_KEY_ID},
        )
        _apns_jwt_cache["token"] = token
        _apns_jwt_cache["expires"] = now + 3300   # refresh 5 min before 1-hr expiry
        return token
    except Exception as e:
        logger.error(f"APNs JWT generation failed: {e}")
        return None


def _send_apns_sync(
    device_token: str,
    title: str,
    body: str,
    subtitle: str = "",
    user_info: Optional[dict] = None,
    sandbox: bool = False,
) -> bool:
    """Send a single APNs push notification (synchronous, HTTP/2). Returns True on success."""
    jwt_token = _get_apns_jwt()
    if not jwt_token or not APNS_BUNDLE_ID:
        return False
    host = "api.sandbox.push.apple.com" if sandbox else "api.push.apple.com"
    url  = f"https://{host}/3/device/{device_token}"
    payload: dict = {
        "aps": {
            "alert": {"title": title, "body": body},
            "sound": "default",
        }
    }
    if subtitle:
        payload["aps"]["alert"]["subtitle"] = subtitle
    if user_info:
        payload.update(user_info)
    headers = {
        "authorization": f"bearer {jwt_token}",
        "apns-push-type": "alert",
        "apns-priority": "10",
        "apns-topic": APNS_BUNDLE_ID,
    }
    try:
        with httpx.Client(http2=True, timeout=10) as client:
            resp = client.post(url, json=payload, headers=headers)
            if resp.status_code != 200:
                logger.warning(f"APNs {resp.status_code} for token …{device_token[-8:]}: {resp.text[:200]}")
                return False
            return True
    except Exception as e:
        logger.error(f"APNs send error: {e}")
        return False


# Server-side state for APNs price alerts (in-memory; resets on restart — acceptable)
_apns_last_prices:         dict[str, float] = {}  # symbol → last checked price (USD)
_apns_cooldowns:           dict[str, float] = {}  # symbol → timestamp of last per-symbol push
_apns_portfolio_values:    dict[str, float] = {}  # user_id → last total portfolio value (USD)
_apns_portfolio_cooldowns: dict[str, float] = {}  # user_id → timestamp of last portfolio push


def _apns_price_alert_job() -> None:
    """
    APScheduler job — runs every 5 min.
    • Proactively fetches fresh stock quotes for every user's held stocks.
    • Sends per-symbol APNs push if any asset moves ≥ 4 % since last check.
    • Sends portfolio-level push if the total portfolio value moves ≥ 5 %.
    """
    if not _get_apns_jwt():
        return  # APNs not configured — skip silently
    db = SessionLocal()
    try:
        tokens: list = db.query(models.DeviceToken).all()
        if not tokens:
            return

        # Group tokens by user_id
        token_map: dict = {}
        for t in tokens:
            token_map.setdefault(t.user_id, []).append((t.token, bool(t.sandbox)))

        # Crypto prices from cache (populated by the regular cache refresh)
        crypto_prices: dict = dict(_crypto_cache.get("prices", {}))
        fx_to_usd: dict = _fx_cache.get("fx_to_usd") or {}
        now_ts = time.time()

        for user_id, user_tokens in token_map.items():
            # ── Load user holdings ───────────────────────────────────────────
            acct_ids = [
                a.id for a in db.query(models.Account)
                .filter(models.Account.user_id == user_id).all()
            ]
            if not acct_ids:
                continue
            rows = (
                db.query(models.Holding, models.Asset, models.Account)
                .join(models.Asset, models.Holding.asset_id == models.Asset.id)
                .join(models.Account, models.Holding.account_id == models.Account.id)
                .filter(
                    models.Holding.account_id.in_(acct_ids),
                    models.Holding.quantity > 1e-8,
                )
                .all()
            )
            if not rows:
                continue

            # ── Proactively fetch fresh stock/ETF prices ─────────────────────
            stock_syms = list({
                r.Asset.symbol.upper() for r in rows
                if r.Asset.asset_class in ("stock", "etf")
            })
            fresh_stock_prices: dict = {}
            if stock_syms:
                try:
                    fetched = _fetch_yahoo_quotes(stock_syms)
                    for sym, data in fetched.items():
                        price = float(data.get("last") or data.get("price") or 0)
                        if price > 0:
                            fresh_stock_prices[sym] = price
                            # Populate the shared stock cache so other endpoints benefit too
                            _stock_cache[sym] = {**data, "price": price, "ts": now_ts}
                except Exception as e:
                    logger.warning(f"APNs stock fetch error for user {user_id}: {e}")

            # ── Per-symbol volatility check ──────────────────────────────────
            triggered: list = []
            total_value_usd = 0.0

            for r in rows:
                holding, asset, account = r
                sym = asset.symbol.upper()
                ac  = asset.asset_class

                # Resolve current USD price
                if ac in ("stock", "etf"):
                    price_usd = fresh_stock_prices.get(sym, 0)
                    # Convert non-USD quoted stocks (e.g. VUSA.AS quoted in EUR)
                    ccy = (asset.quote_currency or "USD").upper()
                    if ccy != "USD" and price_usd > 0:
                        rate = fx_to_usd.get(ccy, 0)
                        price_usd = price_usd / rate if rate > 0 else price_usd
                elif ac == "crypto":
                    price_usd = crypto_prices.get(sym, 0)
                elif ac == "fiat":
                    ccy = (asset.quote_currency or sym).upper()
                    rate = fx_to_usd.get(ccy, 0)
                    price_usd = 1.0 / rate if rate > 0 else 0
                else:
                    continue

                if price_usd <= 0:
                    continue

                # Accumulate portfolio total
                total_value_usd += holding.quantity * price_usd

                # Per-symbol alert (skip fiat — FX noise isn't actionable)
                if ac in ("stock", "etf", "crypto"):
                    last = _apns_last_prices.get(sym)
                    if last and last > 0:
                        pct = ((price_usd - last) / last) * 100
                        if abs(pct) >= 3 and now_ts - _apns_cooldowns.get(sym, 0) > 3600:
                            triggered.append((sym, pct))
                            _apns_cooldowns[sym] = now_ts
                    _apns_last_prices[sym] = price_usd

            # ── Portfolio-level alert (≥ 5 % total swing) ───────────────────
            last_portfolio = _apns_portfolio_values.get(user_id, 0)
            if last_portfolio > 0 and total_value_usd > 0:
                port_pct = ((total_value_usd - last_portfolio) / last_portfolio) * 100
                if abs(port_pct) >= 3 and now_ts - _apns_portfolio_cooldowns.get(user_id, 0) > 3600:
                    _apns_portfolio_cooldowns[user_id] = now_ts
                    icon  = "📈" if port_pct > 0 else "📉"
                    direction = "up" if port_pct > 0 else "down"
                    push_title = f"{icon} Portfolio {direction} {abs(port_pct):.1f}%"
                    push_body  = (
                        f"Your total portfolio is {direction} "
                        f"{abs(port_pct):.1f}% — open LedgerVault to review."
                    )
                    for token, sandbox in user_tokens:
                        _send_apns_sync(token, push_title, push_body, sandbox=sandbox)

            if total_value_usd > 0:
                _apns_portfolio_values[user_id] = total_value_usd

            # ── Per-symbol pushes (worst 2 movers per cycle) ─────────────────
            for sym, pct in sorted(triggered, key=lambda x: abs(x[1]), reverse=True)[:2]:
                direction = "▲" if pct > 0 else "▼"
                push_title = f"{direction} {sym} moved {abs(pct):.1f}%"
                push_body  = (
                    f"{sym} is {'up' if pct > 0 else 'down'} "
                    f"{abs(pct):.1f}% in your portfolio."
                )
                for token, sandbox in user_tokens:
                    _send_apns_sync(token, push_title, push_body, sandbox=sandbox)

    except Exception as e:
        logger.error(f"APNs price alert job error: {e}")
    finally:
        db.close()


# Register the APNs job NOW — after the function is defined, but scheduler is already running
_scheduler.add_job(_apns_price_alert_job, "interval", minutes=5, id="apns_price_alerts")


# ─────────────────────────────────────────────
# FX  (open.er-api.com — free, no key)
# ─────────────────────────────────────────────
FX_PROVIDER_URL      = os.getenv("FX_PROVIDER_URL", "https://open.er-api.com/v6/latest/USD")
FX_CACHE_TTL_SECONDS = int(os.getenv("FX_CACHE_TTL_SECONDS", "60"))
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

# Stablecoins must never be used as an account base_currency — map them to their
# underlying fiat so balance maths and FX conversions work correctly.
_STABLECOIN_TO_FIAT: dict[str, str] = {
    "USDT": "USD", "USDC": "USD", "BUSD": "USD", "DAI":   "USD",
    "TUSD": "USD", "USDP": "USD", "GUSD": "USD", "LUSD":  "USD",
    "FRAX": "USD", "USDD": "USD", "PYUSD":"USD", "FDUSD": "USD",
    "EURT": "EUR", "EURS": "EUR", "AGEUR":"EUR",
}

def normalize_base_currency(currency: str) -> str:
    """Return the real fiat symbol for stablecoin inputs, else uppercase as-is."""
    upper = currency.strip().upper()
    return _STABLECOIN_TO_FIAT.get(upper, upper)

# ─────────────────────────────────────────────
# CRYPTO PRICES  (CoinGecko — free, no key)
# ─────────────────────────────────────────────
CRYPTO_CACHE_TTL = int(os.getenv("CRYPTO_CACHE_TTL_SECONDS", "120"))
_crypto_cache = {"ts": 0.0, "prices": {}, "meta": {}}   # symbol.upper() → price_usd / full coin meta

# Stablecoins are always $1 (±tiny deviation) — never fetch these from CoinGecko
# so a CoinGecko outage never zeros-out stablecoin portfolio values.
_STABLECOIN_HARDCODED_USD: dict[str, float] = {
    "USDT": 1.0, "USDC": 1.0, "BUSD": 1.0, "DAI": 1.0, "TUSD": 1.0,
    "USDP": 1.0, "FRAX": 1.0, "LUSD": 1.0, "PYUSD": 1.0, "FDUSD": 1.0,
    "GUSD": 1.0, "PAX": 1.0, "USDD": 1.0, "USDE": 1.0, "SUSDE": 1.0,
    "USDBC": 1.0, "USDS": 1.0, "CUSD": 1.0,
}

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

def _fetch_binance_spot_prices() -> dict[str, float]:
    """Binance public ticker — no API key, returns USDT-pair prices as USD."""
    try:
        with httpx.Client(timeout=8.0) as c:
            r = c.get("https://api.binance.com/api/v3/ticker/price")
            r.raise_for_status()
        prices: dict[str, float] = {}
        for t in r.json():
            sym: str = t.get("symbol", "")
            if sym.endswith("USDT"):
                base = sym[:-4]  # e.g. "BTCUSDT" → "BTC"
                try:
                    prices[base] = float(t["price"])
                except (ValueError, KeyError):
                    pass
        return prices
    except Exception:
        logger.warning("Binance fallback fetch failed")
        return {}

def _fetch_crypto_prices() -> dict:
    now = time.time()
    if _crypto_cache["prices"] and (now - _crypto_cache["ts"]) < CRYPTO_CACHE_TTL:
        return _crypto_cache["prices"]

    prices: dict[str, float] = {}
    meta: dict[str, dict] = {}

    # ── Primary: CoinGecko top-250 ────────────────────────────────────────────
    try:
        with httpx.Client(timeout=12.0) as c:
            r = c.get(COINGECKO_TOP_URL); r.raise_for_status()
            coins = r.json()
        for coin in coins:
            sym = coin.get("symbol", "").upper()
            p   = coin.get("current_price")
            if sym and p is not None:
                price = float(p)
                chg_pct = float(coin.get("price_change_percentage_24h") or 0.0)
                prices[sym] = price
                meta[sym] = {
                    "name":       coin.get("name", sym),
                    "image":      coin.get("image", ""),
                    "change_pct": round(chg_pct, 4),
                    "change":     round(price * chg_pct / 100, 6),
                }
    except Exception:
        logger.exception("CoinGecko prices fetch failed — trying Binance fallback")

    # ── Fallback: Binance spot (no key, fills gaps when CoinGecko fails/rate-limits) ──
    if len(prices) < 20:
        for sym, p in _fetch_binance_spot_prices().items():
            if sym not in prices:
                prices[sym] = p

    # ── Always inject hardcoded stablecoin prices ($1) ────────────────────────
    # These are rock-stable; a CoinGecko outage must never zero stablecoin values.
    for sym, p in _STABLECOIN_HARDCODED_USD.items():
        prices.setdefault(sym, p)   # only fills gaps — real price wins if available

    if prices:
        _crypto_cache.update({"ts": now, "prices": prices, "meta": meta})
        return prices
    # Last resort: serve stale cache (better than zeros)
    return _crypto_cache.get("prices", {}) or dict(_STABLECOIN_HARDCODED_USD)

# ─────────────────────────────────────────────
# STOCK PRICES  (Yahoo Finance — free, no key)
# ─────────────────────────────────────────────
STOCK_CACHE_TTL = int(os.getenv("STOCK_CACHE_TTL_SECONDS", "30"))

# ── Wallet explorer API keys (free tiers — optional but improves rate limits) ─
ETHERSCAN_KEY   = os.getenv("ETHERSCAN_API_KEY",   "")
BSCSCAN_KEY     = os.getenv("BSCSCAN_API_KEY",     "")
POLYGONSCAN_KEY = os.getenv("POLYGONSCAN_API_KEY", "")
_stock_cache: dict[str, dict] = {}   # symbol → {price, change_pct, exchange, name, ts}

def _fetch_stock_price(symbol: str, preferred_currency: str | None = None) -> dict | None:
    sym = symbol.upper()
    cached = _stock_cache.get(sym)
    if cached and (time.time() - cached["ts"]) < STOCK_CACHE_TTL:
        return cached

    # Build suffix order based on preferred currency so we hit the right exchange first.
    # EUR  → Euronext Amsterdam/Paris/Frankfurt/Milan before LSE
    # GBP  → LSE first
    # default (USD or unknown) → try bare symbol, then LSE, then EU exchanges
    if "." in sym:
        suffixes_to_try = [sym]
    elif preferred_currency and preferred_currency.upper() == "EUR":
        suffixes_to_try = [sym, f"{sym}.AS", f"{sym}.PA", f"{sym}.DE", f"{sym}.MI", f"{sym}.L"]
    elif preferred_currency and preferred_currency.upper() == "GBP":
        suffixes_to_try = [sym, f"{sym}.L", f"{sym}.AS", f"{sym}.PA", f"{sym}.DE", f"{sym}.MI"]
    else:
        suffixes_to_try = [sym, f"{sym}.L", f"{sym}.AS", f"{sym}.PA", f"{sym}.DE", f"{sym}.MI"]

    def _try_fetch(ticker: str) -> dict | None:
        try:
            url = f"https://query1.finance.yahoo.com/v8/finance/chart/{ticker}?interval=1d&range=1d"
            with httpx.Client(timeout=8.0, headers={"User-Agent": "Mozilla/5.0"}) as c:
                r = c.get(url); r.raise_for_status()
                data = r.json()
            meta = data["chart"]["result"][0]["meta"]
            price  = float(meta.get("regularMarketPrice", 0))
            if price == 0:
                return None
            prev   = float(meta.get("chartPreviousClose", price) or price)
            chg    = ((price - prev) / prev * 100) if prev else 0.0
            exch_code = meta.get("exchangeName", "")
            exch_full = meta.get("fullExchangeName", exch_code)
            exchange_map = {
                "NMS": "NASDAQ", "NGM": "NASDAQ", "NCM": "NASDAQ",
                "NYQ": "NYSE", "ASE": "NYSE American",
                "PCX": "NYSE Arca", "BTS": "BATS",
                "NasdaqGS": "NASDAQ", "NasdaqGM": "NASDAQ", "NasdaqCM": "NASDAQ",
                "LSE": "LSE", "IOB": "LSE",
            }
            exch = exchange_map.get(exch_code, exch_full or exch_code)
            return {
                "symbol": sym, "price": price, "change_pct": round(chg, 2),
                "exchange": exch, "name": meta.get("shortName", ticker),
                "currency": meta.get("currency", "USD"),
                "market_state": meta.get("marketState", "CLOSED"), "ts": time.time()
            }
        except Exception:
            return None

    for ticker in suffixes_to_try:
        result = _try_fetch(ticker)
        if result:
            _stock_cache[sym] = result
            return result

    logger.warning(f"Yahoo stock fetch failed for {sym} (tried: {suffixes_to_try})")
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
                holding.quantity = new_qty   # allow negative (liability / offset accounts)
                if new_qty == 0.0:
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
        holding.quantity = new_qty   # allow negative (liability / offset accounts)
        if new_qty == 0.0:
            db.delete(holding)

        db.add(models.TransactionLeg(
            id=str(uuid4()), event_id=event_id,
            account_id=leg_data["account_id"],
            asset_id=leg_data["asset_id"],
            quantity=leg_data["quantity"],
            unit_price=leg_data.get("unit_price"),
            fee_flag=leg_data.get("fee_flag", "false"),
        ))


# ── Gate.io ──────────────────────────────────────────────────────────────────
def _sync_gate(conn: models.ExchangeConnection, db: Session) -> SyncResult:
    """Sync Gate.io spot trade history."""
    imported, skipped, errors = 0, 0, []
    base = "https://api.gateio.ws/api/v4"

    def gate_headers(method: str, path: str, query: str = "", body: str = "") -> dict:
        ts = str(int(time.time()))
        body_hash = hashlib.sha512(body.encode()).hexdigest()
        msg = f"{method}\n{path}\n{query}\n{body_hash}\n{ts}"
        sig = hmac.new(conn.api_secret.encode(), msg.encode(), hashlib.sha512).hexdigest()
        return {"KEY": conn.api_key, "SIGN": sig, "Timestamp": ts, "Content-Type": "application/json"}

    try:
        headers = gate_headers("GET", "/api/v4/spot/my_trades", "limit=1000")
        with httpx.Client(timeout=15.0) as c:
            r = c.get(f"{base}/spot/my_trades?limit=1000", headers=headers)
            r.raise_for_status()
            all_trades = r.json()
    except Exception as e:
        return SyncResult(imported=0, skipped=0, errors=[f"Gate.io auth failed: {e}"], status="error")

    target_account = db.query(models.Account).filter(models.Account.id == conn.account_id).first() if conn.account_id else None
    if not target_account:
        return SyncResult(imported=0, skipped=0, errors=["No linked account"], status="error")

    for trade in all_trades:
        ext_id = f"gate:{trade['id']}"
        if db.query(models.TransactionEvent).filter(models.TransactionEvent.external_id == ext_id).first():
            skipped += 1; continue
        try:
            parts = trade["currency_pair"].split("_")
            base_sym, quote_sym = parts[0].upper(), parts[1].upper()
            qty = float(trade["amount"])
            price = float(trade["price"])
            is_buy = trade["side"] == "buy"
            fee = float(trade.get("fee", 0))
            fee_asset = trade.get("fee_currency", quote_sym).upper()
            trade_date = datetime.fromtimestamp(float(trade["create_time"]), tz=timezone.utc).strftime("%Y-%m-%d")
            base_asset = db.query(models.Asset).filter(models.Asset.symbol == base_sym).first()
            quote_asset = db.query(models.Asset).filter(models.Asset.symbol == quote_sym).first()
            if not base_asset: skipped += 1; continue
            legs = []
            if is_buy:
                legs.append({"account_id": target_account.id, "asset_id": base_asset.id, "quantity": qty, "unit_price": price, "fee_flag": "false"})
                if quote_asset: legs.append({"account_id": target_account.id, "asset_id": quote_asset.id, "quantity": -(qty * price), "unit_price": None, "fee_flag": "false"})
            else:
                legs.append({"account_id": target_account.id, "asset_id": base_asset.id, "quantity": -qty, "unit_price": price, "fee_flag": "false"})
                if quote_asset: legs.append({"account_id": target_account.id, "asset_id": quote_asset.id, "quantity": qty * price, "unit_price": None, "fee_flag": "false"})
            if fee > 0:
                fa = db.query(models.Asset).filter(models.Asset.symbol == fee_asset).first()
                if fa: legs.append({"account_id": target_account.id, "asset_id": fa.id, "quantity": -fee, "unit_price": None, "fee_flag": "true"})
            event = models.TransactionEvent(id=str(uuid4()), event_type="trade",
                description=f"{'Buy' if is_buy else 'Sell'} {base_sym}/{quote_sym}",
                date=trade_date, source="api", external_id=ext_id)
            db.add(event); db.flush()
            _apply_legs(legs, event.id, db); db.commit(); imported += 1
        except Exception as e:
            db.rollback(); errors.append(str(e))

    return SyncResult(imported=imported, skipped=skipped, errors=errors[:10], status="active" if not errors else "error")


# ── Bitfinex ─────────────────────────────────────────────────────────────────
def _sync_bitfinex(conn: models.ExchangeConnection, db: Session) -> SyncResult:
    """Sync Bitfinex trade history via REST v2."""
    imported, skipped, errors = 0, 0, []
    base = "https://api.bitfinex.com"

    def bfx_headers(path: str, body: dict) -> dict:
        nonce = str(int(time.time() * 1_000_000))
        body_str = json.dumps(body)
        sig_msg = f"/api{path}{nonce}{body_str}"
        sig = hmac.new(conn.api_secret.encode(), sig_msg.encode(), hashlib.sha384).hexdigest()
        return {"bfx-apikey": conn.api_key, "bfx-nonce": nonce, "bfx-signature": sig, "Content-Type": "application/json"}

    try:
        path = "/v2/auth/r/trades/hist"
        body = {"limit": 1000}
        headers = bfx_headers(path, body)
        with httpx.Client(timeout=15.0) as c:
            r = c.post(f"{base}{path}", json=body, headers=headers)
            r.raise_for_status()
            all_trades = r.json()
    except Exception as e:
        return SyncResult(imported=0, skipped=0, errors=[f"Bitfinex auth failed: {e}"], status="error")

    target_account = db.query(models.Account).filter(models.Account.id == conn.account_id).first() if conn.account_id else None
    if not target_account:
        return SyncResult(imported=0, skipped=0, errors=["No linked account"], status="error")

    for trade in all_trades:
        if not isinstance(trade, list) or len(trade) < 9: continue
        trade_id, pair, ts_ms, order_id, exec_qty, exec_price, order_type, _, fee, fee_currency = (trade + [None]*10)[:10]
        ext_id = f"bitfinex:{trade_id}"
        if db.query(models.TransactionEvent).filter(models.TransactionEvent.external_id == ext_id).first():
            skipped += 1; continue
        try:
            pair = (pair or "").replace("t", "", 1)
            if "/" in pair:
                base_sym, quote_sym = pair.split("/")
            elif len(pair) == 6:
                base_sym, quote_sym = pair[:3], pair[3:]
            else:
                base_sym, quote_sym = pair[:-3], pair[-3:]
            base_sym = base_sym.upper().lstrip("t"); quote_sym = quote_sym.upper()
            qty = abs(float(exec_qty)); price = abs(float(exec_price))
            is_buy = float(exec_qty) > 0
            fee_val = abs(float(fee)) if fee else 0
            trade_date = datetime.fromtimestamp(int(ts_ms) / 1000, tz=timezone.utc).strftime("%Y-%m-%d")
            base_asset = db.query(models.Asset).filter(models.Asset.symbol == base_sym).first()
            quote_asset = db.query(models.Asset).filter(models.Asset.symbol == quote_sym).first()
            if not base_asset: skipped += 1; continue
            legs = []
            if is_buy:
                legs.append({"account_id": target_account.id, "asset_id": base_asset.id, "quantity": qty, "unit_price": price, "fee_flag": "false"})
                if quote_asset: legs.append({"account_id": target_account.id, "asset_id": quote_asset.id, "quantity": -(qty * price), "unit_price": None, "fee_flag": "false"})
            else:
                legs.append({"account_id": target_account.id, "asset_id": base_asset.id, "quantity": -qty, "unit_price": price, "fee_flag": "false"})
                if quote_asset: legs.append({"account_id": target_account.id, "asset_id": quote_asset.id, "quantity": qty * price, "unit_price": None, "fee_flag": "false"})
            if fee_val > 0 and fee_currency:
                fa = db.query(models.Asset).filter(models.Asset.symbol == fee_currency.upper().lstrip("f")).first()
                if fa: legs.append({"account_id": target_account.id, "asset_id": fa.id, "quantity": -fee_val, "unit_price": None, "fee_flag": "true"})
            event = models.TransactionEvent(id=str(uuid4()), event_type="trade",
                description=f"{'Buy' if is_buy else 'Sell'} {base_sym}/{quote_sym}",
                date=trade_date, source="api", external_id=ext_id)
            db.add(event); db.flush()
            _apply_legs(legs, event.id, db); db.commit(); imported += 1
        except Exception as e:
            db.rollback(); errors.append(str(e))

    return SyncResult(imported=imported, skipped=skipped, errors=errors[:10], status="active" if not errors else "error")


# ── Gemini ────────────────────────────────────────────────────────────────────
def _sync_gemini(conn: models.ExchangeConnection, db: Session) -> SyncResult:
    """Sync Gemini trade history."""
    imported, skipped, errors = 0, 0, []
    base = "https://api.gemini.com"

    def gemini_request(path: str, payload: dict) -> dict:
        payload["request"] = path
        payload["nonce"] = str(int(time.time() * 1000))
        b64 = base64.b64encode(json.dumps(payload).encode()).decode()
        sig = hmac.new(conn.api_secret.encode(), b64.encode(), hashlib.sha384).hexdigest()
        headers = {"X-GEMINI-APIKEY": conn.api_key, "X-GEMINI-PAYLOAD": b64, "X-GEMINI-SIGNATURE": sig}
        with httpx.Client(timeout=15.0) as c:
            r = c.post(f"{base}{path}", headers=headers)
            r.raise_for_status(); return r.json()

    try:
        all_trades = gemini_request("/v1/mytrades", {"limit_trades": 500})
    except Exception as e:
        return SyncResult(imported=0, skipped=0, errors=[f"Gemini auth failed: {e}"], status="error")

    target_account = db.query(models.Account).filter(models.Account.id == conn.account_id).first() if conn.account_id else None
    if not target_account:
        return SyncResult(imported=0, skipped=0, errors=["No linked account"], status="error")

    for trade in all_trades:
        ext_id = f"gemini:{trade['tid']}"
        if db.query(models.TransactionEvent).filter(models.TransactionEvent.external_id == ext_id).first():
            skipped += 1; continue
        try:
            pair = trade["symbol"].upper()
            # Gemini pairs like "BTCUSD", "ETHUSD", "SOLUSD"
            quote_candidates = ["USD", "BTC", "ETH", "USDC", "GUSD", "DAI"]
            quote_sym = next((q for q in quote_candidates if pair.endswith(q)), pair[-3:])
            base_sym = pair[:-len(quote_sym)]
            qty = float(trade["amount"]); price = float(trade["price"])
            is_buy = trade["type"] == "Buy"
            fee = float(trade.get("fee_amount", 0))
            fee_currency = trade.get("fee_currency", quote_sym).upper()
            trade_date = datetime.fromtimestamp(int(trade["timestampms"]) / 1000, tz=timezone.utc).strftime("%Y-%m-%d")
            base_asset = db.query(models.Asset).filter(models.Asset.symbol == base_sym).first()
            quote_asset = db.query(models.Asset).filter(models.Asset.symbol == quote_sym).first()
            if not base_asset: skipped += 1; continue
            legs = []
            if is_buy:
                legs.append({"account_id": target_account.id, "asset_id": base_asset.id, "quantity": qty, "unit_price": price, "fee_flag": "false"})
                if quote_asset: legs.append({"account_id": target_account.id, "asset_id": quote_asset.id, "quantity": -(qty * price), "unit_price": None, "fee_flag": "false"})
            else:
                legs.append({"account_id": target_account.id, "asset_id": base_asset.id, "quantity": -qty, "unit_price": price, "fee_flag": "false"})
                if quote_asset: legs.append({"account_id": target_account.id, "asset_id": quote_asset.id, "quantity": qty * price, "unit_price": None, "fee_flag": "false"})
            if fee > 0:
                fa = db.query(models.Asset).filter(models.Asset.symbol == fee_currency).first()
                if fa: legs.append({"account_id": target_account.id, "asset_id": fa.id, "quantity": -fee, "unit_price": None, "fee_flag": "true"})
            event = models.TransactionEvent(id=str(uuid4()), event_type="trade",
                description=f"{'Buy' if is_buy else 'Sell'} {base_sym}/{quote_sym}",
                date=trade_date, source="api", external_id=ext_id)
            db.add(event); db.flush()
            _apply_legs(legs, event.id, db); db.commit(); imported += 1
        except Exception as e:
            db.rollback(); errors.append(str(e))

    return SyncResult(imported=imported, skipped=skipped, errors=errors[:10], status="active" if not errors else "error")


# ── HTX (Huobi) ───────────────────────────────────────────────────────────────
def _sync_htx(conn: models.ExchangeConnection, db: Session) -> SyncResult:
    """Sync HTX (Huobi) trade history."""
    imported, skipped, errors = 0, 0, []
    base = "https://api.huobi.pro"

    def htx_sign(method: str, path: str, params: dict) -> dict:
        ts = datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%S")
        p = {"AccessKeyId": conn.api_key, "SignatureMethod": "HmacSHA256",
             "SignatureVersion": "2", "Timestamp": ts}
        p.update(params)
        qs = "&".join(f"{k}={urllib.parse.quote(str(v), safe='')}" for k, v in sorted(p.items()))
        msg = f"{method}\napi.huobi.pro\n{path}\n{qs}"
        sig = base64.b64encode(hmac.new(conn.api_secret.encode(), msg.encode(), hashlib.sha256).digest()).decode()
        p["Signature"] = sig
        return p

    try:
        # Get accounts first
        params = htx_sign("GET", "/v1/account/accounts", {})
        with httpx.Client(timeout=15.0) as c:
            r = c.get(f"{base}/v1/account/accounts", params=params)
            r.raise_for_status()
            accounts_data = r.json()
            if accounts_data.get("status") != "ok":
                raise Exception(accounts_data.get("err-msg", "HTX auth failed"))
            spot_account = next((a for a in accounts_data["data"] if a["type"] == "spot"), None)
            if not spot_account:
                return SyncResult(imported=0, skipped=0, errors=["No spot account found"], status="error")
            acct_id = spot_account["id"]
    except Exception as e:
        return SyncResult(imported=0, skipped=0, errors=[f"HTX auth failed: {e}"], status="error")

    target_account = db.query(models.Account).filter(models.Account.id == conn.account_id).first() if conn.account_id else None
    if not target_account:
        return SyncResult(imported=0, skipped=0, errors=["No linked account"], status="error")

    # Fetch order history (filled orders)
    try:
        params = htx_sign("GET", "/v1/order/matchresults", {"size": 500, "account-id": acct_id})
        with httpx.Client(timeout=15.0) as c:
            r = c.get(f"{base}/v1/order/matchresults", params=params)
            r.raise_for_status()
            data = r.json()
            all_trades = data.get("data", []) if data.get("status") == "ok" else []
    except Exception as e:
        return SyncResult(imported=0, skipped=0, errors=[f"HTX trades fetch failed: {e}"], status="error")

    for trade in all_trades:
        ext_id = f"htx:{trade['id']}"
        if db.query(models.TransactionEvent).filter(models.TransactionEvent.external_id == ext_id).first():
            skipped += 1; continue
        try:
            pair = trade["symbol"].upper()  # e.g. "btcusdt" -> "BTCUSDT"
            quotes = ["USDT", "BTC", "ETH", "HT", "HUSD", "USD"]
            quote_sym = next((q for q in quotes if pair.endswith(q)), pair[-4:])
            base_sym = pair[:-len(quote_sym)]
            qty = float(trade["filled-amount"]); price = float(trade["price"])
            is_buy = "buy" in trade.get("type", "")
            fee = float(trade.get("filled-fees", 0))
            fee_currency = trade.get("fee-currency", quote_sym).upper()
            trade_date = datetime.fromtimestamp(int(trade["created-at"]) / 1000, tz=timezone.utc).strftime("%Y-%m-%d")
            base_asset = db.query(models.Asset).filter(models.Asset.symbol == base_sym).first()
            quote_asset = db.query(models.Asset).filter(models.Asset.symbol == quote_sym).first()
            if not base_asset: skipped += 1; continue
            legs = []
            if is_buy:
                legs.append({"account_id": target_account.id, "asset_id": base_asset.id, "quantity": qty, "unit_price": price, "fee_flag": "false"})
                if quote_asset: legs.append({"account_id": target_account.id, "asset_id": quote_asset.id, "quantity": -(qty * price), "unit_price": None, "fee_flag": "false"})
            else:
                legs.append({"account_id": target_account.id, "asset_id": base_asset.id, "quantity": -qty, "unit_price": price, "fee_flag": "false"})
                if quote_asset: legs.append({"account_id": target_account.id, "asset_id": quote_asset.id, "quantity": qty * price, "unit_price": None, "fee_flag": "false"})
            if fee > 0:
                fa = db.query(models.Asset).filter(models.Asset.symbol == fee_currency).first()
                if fa: legs.append({"account_id": target_account.id, "asset_id": fa.id, "quantity": -fee, "unit_price": None, "fee_flag": "true"})
            event = models.TransactionEvent(id=str(uuid4()), event_type="trade",
                description=f"{'Buy' if is_buy else 'Sell'} {base_sym}/{quote_sym}",
                date=trade_date, source="api", external_id=ext_id)
            db.add(event); db.flush()
            _apply_legs(legs, event.id, db); db.commit(); imported += 1
        except Exception as e:
            db.rollback(); errors.append(str(e))

    return SyncResult(imported=imported, skipped=skipped, errors=errors[:10], status="active" if not errors else "error")


# ── MEXC ──────────────────────────────────────────────────────────────────────
def _sync_mexc(conn: models.ExchangeConnection, db: Session) -> SyncResult:
    """Sync MEXC spot trade history."""
    imported, skipped, errors = 0, 0, []
    base = "https://api.mexc.com"

    try:
        ts = _ms_timestamp()
        params = f"timestamp={ts}&limit=1000"
        sig = _hmac_sha256(conn.api_secret, params)
        headers = {"X-MEXC-APIKEY": conn.api_key}
        with httpx.Client(timeout=15.0) as c:
            r = c.get(f"{base}/api/v3/myTrades?{params}&signature={sig}", headers=headers)
            r.raise_for_status()
            all_trades = r.json()
    except Exception as e:
        return SyncResult(imported=0, skipped=0, errors=[f"MEXC auth failed: {e}"], status="error")

    target_account = db.query(models.Account).filter(models.Account.id == conn.account_id).first() if conn.account_id else None
    if not target_account:
        return SyncResult(imported=0, skipped=0, errors=["No linked account"], status="error")

    quotes = ["USDT", "USDC", "BTC", "ETH", "BNB", "MX"]
    for trade in all_trades:
        ext_id = f"mexc:{trade['id']}"
        if db.query(models.TransactionEvent).filter(models.TransactionEvent.external_id == ext_id).first():
            skipped += 1; continue
        try:
            pair = trade["symbol"].upper()
            quote_sym = next((q for q in quotes if pair.endswith(q)), pair[-4:])
            base_sym = pair[:-len(quote_sym)]
            qty = float(trade["qty"]); price = float(trade["price"])
            is_buy = trade["isBuyer"]
            fee = float(trade.get("commission", 0))
            fee_currency = trade.get("commissionAsset", quote_sym).upper()
            trade_date = datetime.fromtimestamp(int(trade["time"]) / 1000, tz=timezone.utc).strftime("%Y-%m-%d")
            base_asset = db.query(models.Asset).filter(models.Asset.symbol == base_sym).first()
            quote_asset = db.query(models.Asset).filter(models.Asset.symbol == quote_sym).first()
            if not base_asset: skipped += 1; continue
            legs = []
            if is_buy:
                legs.append({"account_id": target_account.id, "asset_id": base_asset.id, "quantity": qty, "unit_price": price, "fee_flag": "false"})
                if quote_asset: legs.append({"account_id": target_account.id, "asset_id": quote_asset.id, "quantity": -(qty * price), "unit_price": None, "fee_flag": "false"})
            else:
                legs.append({"account_id": target_account.id, "asset_id": base_asset.id, "quantity": -qty, "unit_price": price, "fee_flag": "false"})
                if quote_asset: legs.append({"account_id": target_account.id, "asset_id": quote_asset.id, "quantity": qty * price, "unit_price": None, "fee_flag": "false"})
            if fee > 0:
                fa = db.query(models.Asset).filter(models.Asset.symbol == fee_currency).first()
                if fa: legs.append({"account_id": target_account.id, "asset_id": fa.id, "quantity": -fee, "unit_price": None, "fee_flag": "true"})
            event = models.TransactionEvent(id=str(uuid4()), event_type="trade",
                description=f"{'Buy' if is_buy else 'Sell'} {base_sym}/{quote_sym}",
                date=trade_date, source="api", external_id=ext_id)
            db.add(event); db.flush()
            _apply_legs(legs, event.id, db); db.commit(); imported += 1
        except Exception as e:
            db.rollback(); errors.append(str(e))

    return SyncResult(imported=imported, skipped=skipped, errors=errors[:10], status="active" if not errors else "error")


# ── Crypto.com ────────────────────────────────────────────────────────────────
def _sync_cryptocom(conn: models.ExchangeConnection, db: Session) -> SyncResult:
    """Sync Crypto.com Exchange trade history."""
    imported, skipped, errors = 0, 0, []
    base = "https://api.crypto.com/exchange/v1"

    def cdc_request(method: str, params: dict) -> dict:
        nonce = str(int(time.time() * 1000))
        req_id = int(time.time() * 1000)
        payload = {"id": req_id, "method": method, "api_key": conn.api_key, "params": params, "nonce": nonce}
        param_str = "".join(f"{k}{v}" for k, v in sorted(params.items()))
        sig_str = method + str(req_id) + conn.api_key + param_str + nonce
        payload["sig"] = hmac.new(conn.api_secret.encode(), sig_str.encode(), hashlib.sha256).hexdigest()
        with httpx.Client(timeout=15.0) as c:
            r = c.post(f"{base}/private/{method.split('/')[-1]}", json=payload)
            r.raise_for_status()
            data = r.json()
            if data.get("code") != 0:
                raise Exception(data.get("message", "Crypto.com API error"))
            return data.get("result", {})

    try:
        result = cdc_request("private/get-trades", {"page_size": 200})
        all_trades = result.get("data", {}).get("list", [])
    except Exception as e:
        return SyncResult(imported=0, skipped=0, errors=[f"Crypto.com auth failed: {e}"], status="error")

    target_account = db.query(models.Account).filter(models.Account.id == conn.account_id).first() if conn.account_id else None
    if not target_account:
        return SyncResult(imported=0, skipped=0, errors=["No linked account"], status="error")

    for trade in all_trades:
        ext_id = f"cryptocom:{trade['trade_id']}"
        if db.query(models.TransactionEvent).filter(models.TransactionEvent.external_id == ext_id).first():
            skipped += 1; continue
        try:
            pair = trade["instrument_name"]  # e.g. "BTC_USDT"
            parts = pair.split("_")
            base_sym, quote_sym = parts[0].upper(), parts[1].upper()
            qty = float(trade["quantity"]); price = float(trade["traded_price"])
            is_buy = trade["side"] == "BUY"
            fee = float(trade.get("fees", 0))
            fee_currency = trade.get("fee_instrument_name", quote_sym).split("_")[0].upper()
            trade_date = datetime.fromtimestamp(int(trade["trade_time"]) / 1000, tz=timezone.utc).strftime("%Y-%m-%d")
            base_asset = db.query(models.Asset).filter(models.Asset.symbol == base_sym).first()
            quote_asset = db.query(models.Asset).filter(models.Asset.symbol == quote_sym).first()
            if not base_asset: skipped += 1; continue
            legs = []
            if is_buy:
                legs.append({"account_id": target_account.id, "asset_id": base_asset.id, "quantity": qty, "unit_price": price, "fee_flag": "false"})
                if quote_asset: legs.append({"account_id": target_account.id, "asset_id": quote_asset.id, "quantity": -(qty * price), "unit_price": None, "fee_flag": "false"})
            else:
                legs.append({"account_id": target_account.id, "asset_id": base_asset.id, "quantity": -qty, "unit_price": price, "fee_flag": "false"})
                if quote_asset: legs.append({"account_id": target_account.id, "asset_id": quote_asset.id, "quantity": qty * price, "unit_price": None, "fee_flag": "false"})
            if fee > 0:
                fa = db.query(models.Asset).filter(models.Asset.symbol == fee_currency).first()
                if fa: legs.append({"account_id": target_account.id, "asset_id": fa.id, "quantity": -fee, "unit_price": None, "fee_flag": "true"})
            event = models.TransactionEvent(id=str(uuid4()), event_type="trade",
                description=f"{'Buy' if is_buy else 'Sell'} {base_sym}/{quote_sym}",
                date=trade_date, source="api", external_id=ext_id)
            db.add(event); db.flush()
            _apply_legs(legs, event.id, db); db.commit(); imported += 1
        except Exception as e:
            db.rollback(); errors.append(str(e))

    return SyncResult(imported=imported, skipped=skipped, errors=errors[:10], status="active" if not errors else "error")


# ── Bitstamp ──────────────────────────────────────────────────────────────────
def _sync_bitstamp(conn: models.ExchangeConnection, db: Session) -> SyncResult:
    """Sync Bitstamp trade history."""
    imported, skipped, errors = 0, 0, []
    base = "https://www.bitstamp.net/api/v2"

    def bitstamp_headers(path: str) -> dict:
        nonce = str(uuid4()).replace("-", "")
        ts = str(int(time.time() * 1000))
        content_type = "application/x-www-form-urlencoded"
        msg = f"BITSTAMP {conn.api_key}\nPOST\nwww.bitstamp.net\n{path}\n\n{content_type}\n{nonce}\n{ts}\nv2\n"
        sig = hmac.new(conn.api_secret.encode(), msg.encode(), hashlib.sha256).hexdigest().upper()
        return {
            "X-Auth": f"BITSTAMP {conn.api_key}",
            "X-Auth-Signature": sig,
            "X-Auth-Nonce": nonce,
            "X-Auth-Timestamp": ts,
            "X-Auth-Version": "v2",
            "Content-Type": content_type,
        }

    try:
        path = "/user_transactions/"
        headers = bitstamp_headers(path)
        with httpx.Client(timeout=15.0) as c:
            r = c.post(f"{base}{path}", headers=headers, data={"limit": 1000, "transaction_type": 2})
            r.raise_for_status()
            all_trades = r.json()
            if isinstance(all_trades, dict) and "error" in all_trades:
                raise Exception(all_trades["error"])
    except Exception as e:
        return SyncResult(imported=0, skipped=0, errors=[f"Bitstamp auth failed: {e}"], status="error")

    target_account = db.query(models.Account).filter(models.Account.id == conn.account_id).first() if conn.account_id else None
    if not target_account:
        return SyncResult(imported=0, skipped=0, errors=["No linked account"], status="error")

    for trade in all_trades:
        if not isinstance(trade, dict) or trade.get("type") != "2": continue  # type 2 = market trade
        ext_id = f"bitstamp:{trade['id']}"
        if db.query(models.TransactionEvent).filter(models.TransactionEvent.external_id == ext_id).first():
            skipped += 1; continue
        try:
            # Bitstamp returns fields like "btc_usd", "btc", "usd", "btc_usd_trade_id"
            trade_key = next((k for k in trade if k.endswith("_trade_id") and k != "trade_id"), None)
            if not trade_key: skipped += 1; continue
            pair = trade_key.replace("_trade_id", "")
            parts = pair.split("_")
            base_sym, quote_sym = parts[0].upper(), parts[1].upper()
            base_qty = float(trade.get(parts[0], 0))
            quote_qty = float(trade.get(parts[1], 0))
            price = float(trade.get(f"{pair}", trade.get("price", 0)))
            is_buy = base_qty > 0
            fee = float(trade.get("fee", 0))
            trade_date = datetime.fromisoformat(trade["datetime"]).strftime("%Y-%m-%d")
            base_asset = db.query(models.Asset).filter(models.Asset.symbol == base_sym).first()
            quote_asset = db.query(models.Asset).filter(models.Asset.symbol == quote_sym).first()
            if not base_asset: skipped += 1; continue
            qty = abs(base_qty)
            legs = []
            if is_buy:
                legs.append({"account_id": target_account.id, "asset_id": base_asset.id, "quantity": qty, "unit_price": abs(price) if price else None, "fee_flag": "false"})
                if quote_asset: legs.append({"account_id": target_account.id, "asset_id": quote_asset.id, "quantity": quote_qty, "unit_price": None, "fee_flag": "false"})
            else:
                legs.append({"account_id": target_account.id, "asset_id": base_asset.id, "quantity": -qty, "unit_price": abs(price) if price else None, "fee_flag": "false"})
                if quote_asset: legs.append({"account_id": target_account.id, "asset_id": quote_asset.id, "quantity": -quote_qty, "unit_price": None, "fee_flag": "false"})
            if fee > 0 and quote_asset:
                legs.append({"account_id": target_account.id, "asset_id": quote_asset.id, "quantity": -fee, "unit_price": None, "fee_flag": "true"})
            event = models.TransactionEvent(id=str(uuid4()), event_type="trade",
                description=f"{'Buy' if is_buy else 'Sell'} {base_sym}/{quote_sym}",
                date=trade_date, source="api", external_id=ext_id)
            db.add(event); db.flush()
            _apply_legs(legs, event.id, db); db.commit(); imported += 1
        except Exception as e:
            db.rollback(); errors.append(str(e))

    return SyncResult(imported=imported, skipped=skipped, errors=errors[:10], status="active" if not errors else "error")


# ── BitMart ───────────────────────────────────────────────────────────────────
def _sync_bitmart(conn: models.ExchangeConnection, db: Session) -> SyncResult:
    """Sync BitMart trade history."""
    imported, skipped, errors = 0, 0, []
    base = "https://api-cloud.bitmart.com"

    def bm_headers(timestamp: str, memo: str = "") -> dict:
        msg = f"{timestamp}#{conn.passphrase or memo}#"
        sig = hmac.new(conn.api_secret.encode(), msg.encode(), hashlib.sha256).hexdigest()
        return {"X-BM-KEY": conn.api_key, "X-BM-SIGN": sig, "X-BM-TIMESTAMP": timestamp}

    try:
        ts = str(int(time.time() * 1000))
        headers = bm_headers(ts)
        with httpx.Client(timeout=15.0) as c:
            r = c.get(f"{base}/spot/v4/query/order-trades?limit=200", headers=headers)
            r.raise_for_status()
            data = r.json()
            if data.get("code") != 1000:
                raise Exception(data.get("message", "BitMart error"))
            all_trades = data.get("data", {}).get("trades", [])
    except Exception as e:
        return SyncResult(imported=0, skipped=0, errors=[f"BitMart auth failed: {e}"], status="error")

    target_account = db.query(models.Account).filter(models.Account.id == conn.account_id).first() if conn.account_id else None
    if not target_account:
        return SyncResult(imported=0, skipped=0, errors=["No linked account"], status="error")

    for trade in all_trades:
        ext_id = f"bitmart:{trade['tradeId']}"
        if db.query(models.TransactionEvent).filter(models.TransactionEvent.external_id == ext_id).first():
            skipped += 1; continue
        try:
            pair = trade["symbol"].upper()
            parts = pair.split("_")
            base_sym, quote_sym = parts[0], parts[1]
            qty = float(trade["size"]); price = float(trade["price"])
            is_buy = trade["side"] == "buy"
            fee = float(trade.get("fees", 0))
            fee_currency = trade.get("feeCoinName", quote_sym).upper()
            trade_date = datetime.fromtimestamp(int(trade["createTime"]) / 1000, tz=timezone.utc).strftime("%Y-%m-%d")
            base_asset = db.query(models.Asset).filter(models.Asset.symbol == base_sym).first()
            quote_asset = db.query(models.Asset).filter(models.Asset.symbol == quote_sym).first()
            if not base_asset: skipped += 1; continue
            legs = []
            if is_buy:
                legs.append({"account_id": target_account.id, "asset_id": base_asset.id, "quantity": qty, "unit_price": price, "fee_flag": "false"})
                if quote_asset: legs.append({"account_id": target_account.id, "asset_id": quote_asset.id, "quantity": -(qty * price), "unit_price": None, "fee_flag": "false"})
            else:
                legs.append({"account_id": target_account.id, "asset_id": base_asset.id, "quantity": -qty, "unit_price": price, "fee_flag": "false"})
                if quote_asset: legs.append({"account_id": target_account.id, "asset_id": quote_asset.id, "quantity": qty * price, "unit_price": None, "fee_flag": "false"})
            if fee > 0:
                fa = db.query(models.Asset).filter(models.Asset.symbol == fee_currency).first()
                if fa: legs.append({"account_id": target_account.id, "asset_id": fa.id, "quantity": -fee, "unit_price": None, "fee_flag": "true"})
            event = models.TransactionEvent(id=str(uuid4()), event_type="trade",
                description=f"{'Buy' if is_buy else 'Sell'} {base_sym}/{quote_sym}",
                date=trade_date, source="api", external_id=ext_id)
            db.add(event); db.flush()
            _apply_legs(legs, event.id, db); db.commit(); imported += 1
        except Exception as e:
            db.rollback(); errors.append(str(e))

    return SyncResult(imported=imported, skipped=skipped, errors=errors[:10], status="active" if not errors else "error")


# ── Phemex ────────────────────────────────────────────────────────────────────
def _sync_phemex(conn: models.ExchangeConnection, db: Session) -> SyncResult:
    """Sync Phemex spot trade history."""
    imported, skipped, errors = 0, 0, []
    base = "https://api.phemex.com"

    def phemex_headers(path: str, query: str = "") -> dict:
        expiry = str(int(time.time()) + 60)
        msg = path + query + expiry
        sig = hmac.new(conn.api_secret.encode(), msg.encode(), hashlib.sha256).hexdigest()
        return {
            "x-phemex-access-token": conn.api_key,
            "x-phemex-request-expiry": expiry,
            "x-phemex-request-signature": sig,
        }

    try:
        query = "limit=200"
        headers = phemex_headers("/spot/trades", query)
        with httpx.Client(timeout=15.0) as c:
            r = c.get(f"{base}/spot/trades?{query}", headers=headers)
            r.raise_for_status()
            data = r.json()
            if data.get("code") != 0:
                raise Exception(data.get("msg", "Phemex error"))
            all_trades = data.get("data", {}).get("rows", [])
    except Exception as e:
        return SyncResult(imported=0, skipped=0, errors=[f"Phemex auth failed: {e}"], status="error")

    target_account = db.query(models.Account).filter(models.Account.id == conn.account_id).first() if conn.account_id else None
    if not target_account:
        return SyncResult(imported=0, skipped=0, errors=["No linked account"], status="error")

    quotes = ["USDT", "USDC", "BTC", "ETH"]
    for trade in all_trades:
        ext_id = f"phemex:{trade['execId'] if isinstance(trade, dict) else trade[0]}"
        if db.query(models.TransactionEvent).filter(models.TransactionEvent.external_id == ext_id).first():
            skipped += 1; continue
        try:
            if isinstance(trade, list):
                # Phemex returns arrays: [execId, orderID, clOrdID, symbol, side, orderType, execQty, execPrice, ...]
                exec_id, _, _, symbol, side, _, exec_qty, exec_price, *rest = trade
                fee_val = float(rest[3]) / 1e8 if len(rest) > 3 else 0
                ts_ms = int(rest[5]) if len(rest) > 5 else int(time.time() * 1000)
            else:
                exec_id = trade.get("execId"); symbol = trade.get("symbol", "")
                side = trade.get("side", ""); exec_qty = trade.get("execQty", 0)
                exec_price = trade.get("execPrice", 0); fee_val = 0; ts_ms = int(time.time() * 1000)
            pair = symbol.upper()
            quote_sym = next((q for q in quotes if pair.endswith(q)), pair[-4:])
            base_sym = pair[:-len(quote_sym)]
            qty = float(exec_qty) / 1e8; price = float(exec_price) / 1e8
            is_buy = str(side).lower() == "buy"
            trade_date = datetime.fromtimestamp(ts_ms / 1000, tz=timezone.utc).strftime("%Y-%m-%d")
            base_asset = db.query(models.Asset).filter(models.Asset.symbol == base_sym).first()
            quote_asset = db.query(models.Asset).filter(models.Asset.symbol == quote_sym).first()
            if not base_asset or qty <= 0: skipped += 1; continue
            legs = []
            if is_buy:
                legs.append({"account_id": target_account.id, "asset_id": base_asset.id, "quantity": qty, "unit_price": price, "fee_flag": "false"})
                if quote_asset: legs.append({"account_id": target_account.id, "asset_id": quote_asset.id, "quantity": -(qty * price), "unit_price": None, "fee_flag": "false"})
            else:
                legs.append({"account_id": target_account.id, "asset_id": base_asset.id, "quantity": -qty, "unit_price": price, "fee_flag": "false"})
                if quote_asset: legs.append({"account_id": target_account.id, "asset_id": quote_asset.id, "quantity": qty * price, "unit_price": None, "fee_flag": "false"})
            if fee_val > 0 and quote_asset:
                legs.append({"account_id": target_account.id, "asset_id": quote_asset.id, "quantity": -fee_val, "unit_price": None, "fee_flag": "true"})
            event = models.TransactionEvent(id=str(uuid4()), event_type="trade",
                description=f"{'Buy' if is_buy else 'Sell'} {base_sym}/{quote_sym}",
                date=trade_date, source="api", external_id=ext_id)
            db.add(event); db.flush()
            _apply_legs(legs, event.id, db); db.commit(); imported += 1
        except Exception as e:
            db.rollback(); errors.append(str(e))

    return SyncResult(imported=imported, skipped=skipped, errors=errors[:10], status="active" if not errors else "error")


# ── CoinEx ────────────────────────────────────────────────────────────────────
def _sync_coinex(conn: models.ExchangeConnection, db: Session) -> SyncResult:
    """Sync CoinEx trade history."""
    imported, skipped, errors = 0, 0, []
    base = "https://api.coinex.com/v2"

    def coinex_headers(method: str, path: str, body: str = "") -> dict:
        ts = str(int(time.time() * 1000))
        msg = method.upper() + path + body + ts
        sig = hmac.new(conn.api_secret.encode(), msg.encode(), hashlib.sha256).hexdigest()
        return {"X-COINEX-KEY": conn.api_key, "X-COINEX-SIGN": sig, "X-COINEX-TIMESTAMP": ts}

    try:
        path = "/spot/user-deals"
        headers = coinex_headers("GET", path)
        with httpx.Client(timeout=15.0) as c:
            r = c.get(f"{base}{path}?limit=100&page=1", headers=headers)
            r.raise_for_status()
            data = r.json()
            if data.get("code") != 0:
                raise Exception(data.get("message", "CoinEx error"))
            all_trades = data.get("data", {}).get("items", [])
    except Exception as e:
        return SyncResult(imported=0, skipped=0, errors=[f"CoinEx auth failed: {e}"], status="error")

    target_account = db.query(models.Account).filter(models.Account.id == conn.account_id).first() if conn.account_id else None
    if not target_account:
        return SyncResult(imported=0, skipped=0, errors=["No linked account"], status="error")

    for trade in all_trades:
        ext_id = f"coinex:{trade['deal_id']}"
        if db.query(models.TransactionEvent).filter(models.TransactionEvent.external_id == ext_id).first():
            skipped += 1; continue
        try:
            market = trade["market"].upper()  # e.g. "BTCUSDT"
            quotes = ["USDT", "USDC", "BTC", "ETH", "CET"]
            quote_sym = next((q for q in quotes if market.endswith(q)), market[-4:])
            base_sym = market[:-len(quote_sym)]
            qty = float(trade["amount"]); price = float(trade["price"])
            is_buy = trade["side"] == "buy"
            fee = float(trade.get("fee", 0))
            fee_currency = trade.get("fee_asset", quote_sym).upper()
            trade_date = datetime.fromtimestamp(int(trade["created_at"]) / 1000, tz=timezone.utc).strftime("%Y-%m-%d")
            base_asset = db.query(models.Asset).filter(models.Asset.symbol == base_sym).first()
            quote_asset = db.query(models.Asset).filter(models.Asset.symbol == quote_sym).first()
            if not base_asset: skipped += 1; continue
            legs = []
            if is_buy:
                legs.append({"account_id": target_account.id, "asset_id": base_asset.id, "quantity": qty, "unit_price": price, "fee_flag": "false"})
                if quote_asset: legs.append({"account_id": target_account.id, "asset_id": quote_asset.id, "quantity": -(qty * price), "unit_price": None, "fee_flag": "false"})
            else:
                legs.append({"account_id": target_account.id, "asset_id": base_asset.id, "quantity": -qty, "unit_price": price, "fee_flag": "false"})
                if quote_asset: legs.append({"account_id": target_account.id, "asset_id": quote_asset.id, "quantity": qty * price, "unit_price": None, "fee_flag": "false"})
            if fee > 0:
                fa = db.query(models.Asset).filter(models.Asset.symbol == fee_currency).first()
                if fa: legs.append({"account_id": target_account.id, "asset_id": fa.id, "quantity": -fee, "unit_price": None, "fee_flag": "true"})
            event = models.TransactionEvent(id=str(uuid4()), event_type="trade",
                description=f"{'Buy' if is_buy else 'Sell'} {base_sym}/{quote_sym}",
                date=trade_date, source="api", external_id=ext_id)
            db.add(event); db.flush()
            _apply_legs(legs, event.id, db); db.commit(); imported += 1
        except Exception as e:
            db.rollback(); errors.append(str(e))

    return SyncResult(imported=imported, skipped=skipped, errors=errors[:10], status="active" if not errors else "error")


# ── LBank ─────────────────────────────────────────────────────────────────────
def _sync_lbank(conn: models.ExchangeConnection, db: Session) -> SyncResult:
    """Sync LBank trade history."""
    imported, skipped, errors = 0, 0, []
    base = "https://api.lbank.com/v2"

    def lbank_sign(params: dict) -> str:
        sorted_params = "&".join(f"{k}={v}" for k, v in sorted(params.items()))
        return hmac.new(conn.api_secret.encode(), sorted_params.encode(), hashlib.sha256).hexdigest()

    try:
        ts = str(int(time.time() * 1000))
        params = {"api_key": conn.api_key, "timestamp": ts, "current_page": 1, "page_length": 200, "type": "ALL"}
        params["sign"] = lbank_sign(params)
        with httpx.Client(timeout=15.0) as c:
            r = c.post(f"{base}/orders/transaction_history.do", data=params)
            r.raise_for_status()
            data = r.json()
            if str(data.get("result")) != "true":
                raise Exception(data.get("error_code", "LBank error"))
            all_trades = data.get("data", {}).get("transaction", [])
    except Exception as e:
        return SyncResult(imported=0, skipped=0, errors=[f"LBank auth failed: {e}"], status="error")

    target_account = db.query(models.Account).filter(models.Account.id == conn.account_id).first() if conn.account_id else None
    if not target_account:
        return SyncResult(imported=0, skipped=0, errors=["No linked account"], status="error")

    for trade in all_trades:
        ext_id = f"lbank:{trade['txUuid']}"
        if db.query(models.TransactionEvent).filter(models.TransactionEvent.external_id == ext_id).first():
            skipped += 1; continue
        try:
            pair = trade["symbol"].upper()
            parts = pair.split("_")
            base_sym, quote_sym = parts[0], parts[1]
            qty = float(trade["dealAmount"]); price = float(trade["price"])
            is_buy = trade["type"] == "buy"
            fee = float(trade.get("tradeFee", 0))
            trade_date = datetime.fromtimestamp(int(trade["dealTime"]) / 1000, tz=timezone.utc).strftime("%Y-%m-%d")
            base_asset = db.query(models.Asset).filter(models.Asset.symbol == base_sym).first()
            quote_asset = db.query(models.Asset).filter(models.Asset.symbol == quote_sym).first()
            if not base_asset: skipped += 1; continue
            legs = []
            if is_buy:
                legs.append({"account_id": target_account.id, "asset_id": base_asset.id, "quantity": qty, "unit_price": price, "fee_flag": "false"})
                if quote_asset: legs.append({"account_id": target_account.id, "asset_id": quote_asset.id, "quantity": -(qty * price), "unit_price": None, "fee_flag": "false"})
            else:
                legs.append({"account_id": target_account.id, "asset_id": base_asset.id, "quantity": -qty, "unit_price": price, "fee_flag": "false"})
                if quote_asset: legs.append({"account_id": target_account.id, "asset_id": quote_asset.id, "quantity": qty * price, "unit_price": None, "fee_flag": "false"})
            if fee > 0 and quote_asset:
                legs.append({"account_id": target_account.id, "asset_id": quote_asset.id, "quantity": -fee, "unit_price": None, "fee_flag": "true"})
            event = models.TransactionEvent(id=str(uuid4()), event_type="trade",
                description=f"{'Buy' if is_buy else 'Sell'} {base_sym}/{quote_sym}",
                date=trade_date, source="api", external_id=ext_id)
            db.add(event); db.flush()
            _apply_legs(legs, event.id, db); db.commit(); imported += 1
        except Exception as e:
            db.rollback(); errors.append(str(e))

    return SyncResult(imported=imported, skipped=skipped, errors=errors[:10], status="active" if not errors else "error")


# ── Alpaca ────────────────────────────────────────────────────────────────────
def _sync_alpaca(conn: models.ExchangeConnection, db: Session) -> SyncResult:
    """Sync Alpaca broker positions."""
    imported, skipped, errors = 0, 0, []
    is_paper = (conn.passphrase or "").lower() == "paper"
    base = "https://paper-api.alpaca.markets" if is_paper else "https://api.alpaca.markets"
    headers = {"APCA-API-KEY-ID": conn.api_key, "APCA-API-SECRET-KEY": conn.api_secret}

    try:
        with httpx.Client(timeout=15.0) as c:
            r = c.get(f"{base}/v2/positions", headers=headers)
            r.raise_for_status()
            positions = r.json()
    except Exception as e:
        return SyncResult(imported=0, skipped=0, errors=[f"Alpaca auth failed: {e}"], status="error")

    target_account = db.query(models.Account).filter(models.Account.id == conn.account_id).first() if conn.account_id else None
    if not target_account:
        return SyncResult(imported=0, skipped=0, errors=["No linked account"], status="error")

    for pos in positions:
        sym = pos["symbol"].upper()
        ext_id = f"alpaca:pos:{sym}:{target_account.id}"
        try:
            qty = float(pos["qty"]); avg_cost = float(pos["avg_entry_price"])
            asset = db.query(models.Asset).filter(models.Asset.symbol == sym).first()
            if not asset:
                asset = models.Asset(id=str(uuid4()), symbol=sym, name=pos.get("asset_id", sym),
                                    asset_class="stock", quote_currency="USD")
                db.add(asset); db.flush()
            holding = db.query(models.Holding).filter(
                models.Holding.account_id == target_account.id,
                models.Holding.asset_id == asset.id).first()
            if not holding:
                holding = models.Holding(id=str(uuid4()), account_id=target_account.id,
                                        asset_id=asset.id, quantity=qty, avg_cost=avg_cost)
                db.add(holding)
            else:
                holding.quantity = qty; holding.avg_cost = avg_cost
            db.commit(); imported += 1
        except Exception as e:
            db.rollback(); errors.append(f"{sym}: {e}")

    return SyncResult(imported=imported, skipped=skipped, errors=errors[:10], status="active" if not errors else "error")


SYNC_FUNCTIONS = {
    "binance":   _sync_binance,
    "kraken":    _sync_kraken,
    "coinbase":  _sync_coinbase,
    "bybit":     _sync_bybit,
    "kucoin":    _sync_kucoin,
    "okx":       _sync_okx,
    "gate":      _sync_gate,
    "bitfinex":  _sync_bitfinex,
    "gemini":    _sync_gemini,
    "htx":       _sync_htx,
    "mexc":      _sync_mexc,
    "cryptocom": _sync_cryptocom,
    "bitstamp":  _sync_bitstamp,
    "bitmart":   _sync_bitmart,
    "phemex":    _sync_phemex,
    "coinex":    _sync_coinex,
    "lbank":     _sync_lbank,
    "alpaca":    _sync_alpaca,
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
# AUTH ROUTES
# ─────────────────────────────────────────────

@app.post("/auth/register", response_model=AuthResponse)
@limiter.limit("5/minute")
def auth_register(request: Request, payload: RegisterRequest, db: Session = Depends(get_db)):
    email = payload.email.strip().lower()
    existing = db.query(models.User).filter(models.User.email == email).first()
    if existing:
        if not existing.is_verified:
            # Unverified user trying again — resend the verification code
            code = _gen_otp()
            existing.verify_code = code
            existing.verify_expires = _otp_expires()
            db.commit()
            _send_email(email, "Verify your LedgerVault account",
                f"<p>Your verification code is: <strong>{code}</strong></p>"
                f"<p>It expires in 15 minutes.</p>")
            return AuthResponse(status="needs_verification", email=email,
                                message="Check your email for a 6-digit verification code.")
        raise HTTPException(status_code=409, detail="Email already registered")
    code = _gen_otp()
    user = models.User(
        id=str(uuid4()), email=email,
        password_hash=pwd_context.hash(payload.password[:72]),
        name=payload.name.strip() or None,
        is_verified=False,
        verify_code=code, verify_expires=_otp_expires(),
        created_at=datetime.now(timezone.utc).isoformat(),
    )
    db.add(user); db.commit()
    _send_email(email, "Verify your LedgerVault account",
        f"<p>Your verification code is: <strong>{code}</strong></p>"
        f"<p>It expires in 15 minutes.</p>")
    return AuthResponse(status="needs_verification", email=email,
                        message="Check your email for a 6-digit verification code.")

@app.post("/auth/verify-email", response_model=AuthResponse)
@limiter.limit("10/minute")
def auth_verify_email(request: Request, payload: VerifyEmailRequest, db: Session = Depends(get_db)):
    email = payload.email.strip().lower()
    user = db.query(models.User).filter(models.User.email == email).first()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    if user.verify_code != payload.code or not _otp_valid(user.verify_expires):
        raise HTTPException(status_code=400, detail="Invalid or expired code")
    user.is_verified = True
    user.verify_code = None
    user.verify_expires = None
    db.commit()
    token = _create_token(user.id)
    return AuthResponse(status="ok", access_token=token,
                        user_id=user.id, email=user.email, name=user.name)

@app.post("/auth/resend-code", response_model=AuthResponse)
@limiter.limit("3/minute")
def auth_resend_code(request: Request, payload: ResendCodeRequest, db: Session = Depends(get_db)):
    email = payload.email.strip().lower()
    user = db.query(models.User).filter(models.User.email == email).first()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    if user.is_verified:
        raise HTTPException(status_code=400, detail="Email already verified")
    code = _gen_otp()
    user.verify_code = code
    user.verify_expires = _otp_expires()
    db.commit()
    _send_email(email, "Your new LedgerVault verification code",
        f"<p>Your new verification code is: <strong>{code}</strong></p>"
        f"<p>It expires in 15 minutes.</p>")
    return AuthResponse(status="needs_verification", email=email,
                        message="A new code has been sent to your email.")

@app.post("/auth/login", response_model=AuthResponse)
@limiter.limit("5/minute")
def auth_login(request: Request, payload: LoginRequest, db: Session = Depends(get_db)):
    email = payload.email.strip().lower()
    user = db.query(models.User).filter(models.User.email == email).first()
    if not user or not user.password_hash:
        raise HTTPException(status_code=401, detail="Invalid email or password")
    if not pwd_context.verify(payload.password[:72], user.password_hash):
        raise HTTPException(status_code=401, detail="Invalid email or password")
    if not user.is_verified:
        # Re-send verification code
        code = _gen_otp()
        user.verify_code = code
        user.verify_expires = _otp_expires()
        db.commit()
        _send_email(email, "Verify your LedgerVault account",
            f"<p>Your verification code is: <strong>{code}</strong></p>"
            f"<p>It expires in 15 minutes.</p>")
        return AuthResponse(status="needs_verification", email=email,
                            message="Please verify your email first. A new code has been sent.")
    # TOTP check
    if user.totp_enabled and user.totp_secret:
        if not payload.totp_code:
            return AuthResponse(status="totp_required", email=email,
                                totp_required=True,
                                message="Two-factor authentication code required.")
        totp = pyotp.TOTP(user.totp_secret)
        if not totp.verify(payload.totp_code, valid_window=1):
            raise HTTPException(status_code=401, detail="Invalid two-factor authentication code")
    token = _create_token(user.id)
    return AuthResponse(status="ok", access_token=token,
                        user_id=user.id, email=user.email, name=user.name)

@app.post("/auth/forgot-password", response_model=AuthResponse)
@limiter.limit("3/minute")
def auth_forgot_password(request: Request, payload: ForgotPasswordRequest, db: Session = Depends(get_db)):
    email = payload.email.strip().lower()
    user = db.query(models.User).filter(models.User.email == email).first()
    # Always return success to not leak whether email exists
    if user:
        code = _gen_otp()
        user.reset_code = code
        user.reset_expires = _otp_expires()
        db.commit()
        _send_email(email, "Reset your LedgerVault password",
            f"<p>Your password reset code is: <strong>{code}</strong></p>"
            f"<p>It expires in 15 minutes.</p>")
    return AuthResponse(status="ok",
                        message="If that email is registered, a reset code has been sent.")

@app.post("/auth/reset-password", response_model=AuthResponse)
@limiter.limit("5/minute")
def auth_reset_password(request: Request, payload: ResetPasswordRequest, db: Session = Depends(get_db)):
    email = payload.email.strip().lower()
    user = db.query(models.User).filter(models.User.email == email).first()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    if user.reset_code != payload.code or not _otp_valid(user.reset_expires):
        raise HTTPException(status_code=400, detail="Invalid or expired code")
    user.password_hash = pwd_context.hash(payload.new_password[:72])
    user.reset_code = None
    user.reset_expires = None
    user.is_verified = True   # reset also implicitly verifies
    db.commit()
    token = _create_token(user.id)
    return AuthResponse(status="ok", access_token=token,
                        user_id=user.id, email=user.email, name=user.name)

@app.post("/auth/social", response_model=AuthResponse)
@limiter.limit("5/minute")
def auth_social(request: Request, payload: SocialAuthRequest, db: Session = Depends(get_db)):
    email = payload.email.strip().lower()
    user = None
    # Look up by social ID first — works even when Apple doesn't return email on repeat sign-ins
    if payload.apple_user_id:
        user = db.query(models.User).filter(models.User.apple_user_id == payload.apple_user_id).first()
    if not user and payload.google_sub:
        user = db.query(models.User).filter(models.User.google_sub == payload.google_sub).first()
    if not user and email:
        user = db.query(models.User).filter(models.User.email == email).first()
    is_new_user = False
    if not user:
        # Create new user via social — pre-verified
        user = models.User(
            id=str(uuid4()), email=email,
            name=payload.name.strip() or None,
            is_verified=True,
            apple_user_id=payload.apple_user_id or None,
            google_sub=payload.google_sub or None,
            created_at=datetime.now(timezone.utc).isoformat(),
        )
        db.add(user); db.commit()
        is_new_user = True
    else:
        # Update social identifiers if missing
        changed = False
        if payload.apple_user_id and not user.apple_user_id:
            user.apple_user_id = payload.apple_user_id; changed = True
        if payload.google_sub and not user.google_sub:
            user.google_sub = payload.google_sub; changed = True
        if payload.name and not user.name:
            user.name = payload.name.strip(); changed = True
        if changed:
            db.commit()
    token = _create_token(user.id)
    return AuthResponse(status="ok", access_token=token,
                        user_id=user.id, email=user.email, name=user.name,
                        is_new_user=is_new_user)

@app.get("/auth/me", response_model=AuthResponse)
def auth_me(user_id: str = Depends(require_user_id), db: Session = Depends(get_db)):
    user = db.query(models.User).filter(models.User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    return AuthResponse(status="ok", user_id=user.id, email=user.email, name=user.name)

@app.patch("/auth/profile")
@limiter.limit("10/minute")
def update_profile(request: Request, payload: UpdateProfileRequest,
                   user_id: str = Depends(require_user_id), db: Session = Depends(get_db)):
    """Update profile fields (phone, name). Phone must be globally unique."""
    user = db.query(models.User).filter(models.User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    if payload.phone is not None:
        phone = payload.phone.strip()
        if phone:
            existing = db.query(models.User).filter(
                models.User.phone == phone,
                models.User.id != user_id
            ).first()
            if existing:
                raise HTTPException(status_code=409, detail="Mobile number already in use")
            user.phone = phone
        else:
            user.phone = None
    if payload.name is not None and payload.name.strip():
        user.name = payload.name.strip()
    db.commit()
    return {"status": "ok", "message": "Profile updated"}

@app.get("/auth/totp/status", response_model=TotpStatusResponse)
def totp_status(user_id: str = Depends(require_user_id), db: Session = Depends(get_db)):
    """Returns whether TOTP is currently enabled for the authenticated user."""
    user = db.query(models.User).filter(models.User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    return TotpStatusResponse(enabled=bool(user.totp_enabled))

@app.post("/auth/totp/setup", response_model=TotpSetupResponse)
@limiter.limit("5/minute")
def totp_setup(request: Request, user_id: str = Depends(require_user_id), db: Session = Depends(get_db)):
    """
    Generates a fresh TOTP secret and returns the base32 secret + otpauth:// URI.
    The secret is NOT saved yet — the user must confirm a valid code via /auth/totp/enable.
    """
    user = db.query(models.User).filter(models.User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    secret = pyotp.random_base32()
    label  = urllib.parse.quote(user.email or user_id)
    uri    = f"otpauth://totp/LedgerVault:{label}?secret={secret}&issuer=LedgerVault"
    # Temporarily store the pending secret (not yet confirmed) in totp_secret.
    # totp_enabled stays False until confirmed.
    user.totp_secret  = secret
    user.totp_enabled = False
    db.commit()
    return TotpSetupResponse(secret=secret, uri=uri)

@app.post("/auth/totp/enable")
@limiter.limit("5/minute")
def totp_enable(request: Request, payload: TotpVerifyRequest,
                user_id: str = Depends(require_user_id), db: Session = Depends(get_db)):
    """
    Verifies the TOTP code against the pending secret and, on success, enables TOTP.
    Must be called after /auth/totp/setup.
    """
    user = db.query(models.User).filter(models.User.id == user_id).first()
    if not user or not user.totp_secret:
        raise HTTPException(status_code=400, detail="No pending TOTP setup. Call /auth/totp/setup first.")
    totp = pyotp.TOTP(user.totp_secret)
    if not totp.verify(payload.code, valid_window=1):
        raise HTTPException(status_code=400, detail="Invalid TOTP code. Check your authenticator app and try again.")
    user.totp_enabled = True
    db.commit()
    return {"status": "ok", "message": "Two-factor authentication enabled"}

@app.post("/auth/totp/disable")
@limiter.limit("5/minute")
def totp_disable(request: Request, payload: TotpVerifyRequest,
                 user_id: str = Depends(require_user_id), db: Session = Depends(get_db)):
    """
    Verifies the current TOTP code and disables TOTP. Requires a valid code to prevent accidental lock-out.
    """
    user = db.query(models.User).filter(models.User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    if not user.totp_enabled or not user.totp_secret:
        raise HTTPException(status_code=400, detail="TOTP is not currently enabled.")
    totp = pyotp.TOTP(user.totp_secret)
    if not totp.verify(payload.code, valid_window=1):
        raise HTTPException(status_code=400, detail="Invalid TOTP code.")
    user.totp_enabled = False
    user.totp_secret  = None
    db.commit()
    return {"status": "ok", "message": "Two-factor authentication disabled"}

@app.post("/auth/logout")
def auth_logout(user_id: str = Depends(require_user_id), db: Session = Depends(get_db)):
    """Invalidate all existing tokens for this user by recording the logout timestamp."""
    user = db.query(models.User).filter(models.User.id == user_id).first()
    if user:
        user.logout_at = datetime.now(timezone.utc).isoformat()
        db.commit()
    return {"status": "ok", "message": "Signed out"}

@app.delete("/auth/account")
def auth_delete_account(user_id: str = Depends(require_user_id), db: Session = Depends(get_db)):
    """Hard-delete the authenticated user and ALL their data."""
    user = db.query(models.User).filter(models.User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")

    # Get all account IDs belonging to this user
    account_ids = [a.id for a in db.query(models.Account).filter(models.Account.user_id == user_id).all()]

    if account_ids:
        # Collect event IDs BEFORE deleting legs (otherwise the query returns nothing)
        event_ids = [
            r.event_id for r in
            db.query(models.TransactionLeg.event_id)
              .filter(models.TransactionLeg.account_id.in_(account_ids))
              .distinct().all()
        ]

        # Delete transaction legs first (FK child of events)
        db.query(models.TransactionLeg).filter(
            models.TransactionLeg.account_id.in_(account_ids)
        ).delete(synchronize_session=False)

        # Now delete the events (safe — no legs reference them anymore)
        if event_ids:
            db.query(models.TransactionEvent).filter(
                models.TransactionEvent.id.in_(event_ids)
            ).delete(synchronize_session=False)

        # Delete holdings
        db.query(models.Holding).filter(
            models.Holding.account_id.in_(account_ids)
        ).delete(synchronize_session=False)

        # Delete exchange connections (Binance / Kraken API keys)
        db.query(models.ExchangeConnection).filter(
            models.ExchangeConnection.account_id.in_(account_ids)
        ).delete(synchronize_session=False)

        # Delete bank connections (open-banking tokens)
        db.query(models.BankConnection).filter(
            models.BankConnection.ledger_account_id.in_(account_ids)
        ).delete(synchronize_session=False)

        # Delete recurring transaction rules (account-scoped)
        db.query(models.RecurringTransaction).filter(
            models.RecurringTransaction.from_account_id.in_(account_ids)
        ).delete(synchronize_session=False)

        # Delete accounts
        db.query(models.Account).filter(
            models.Account.user_id == user_id
        ).delete(synchronize_session=False)

    # Delete user-scoped data not tied to a specific account
    db.query(models.SnaptradeConnection).filter(
        models.SnaptradeConnection.user_id == user_id
    ).delete(synchronize_session=False)

    db.query(models.VezgoConnection).filter(
        models.VezgoConnection.user_id == user_id
    ).delete(synchronize_session=False)

    db.query(models.FlanksBrokerConnection).filter(
        models.FlanksBrokerConnection.user_id == user_id
    ).delete(synchronize_session=False)

    db.query(models.AccountProfile).filter(
        models.AccountProfile.user_id == user_id
    ).delete(synchronize_session=False)

    db.query(models.WatchlistItem).filter(
        models.WatchlistItem.user_id == user_id
    ).delete(synchronize_session=False)

    # Remove APNs device tokens so this user no longer receives pushes
    db.query(models.DeviceToken).filter(
        models.DeviceToken.user_id == user_id
    ).delete(synchronize_session=False)

    # Delete any remaining recurring transactions directly tied to user_id
    db.query(models.RecurringTransaction).filter(
        models.RecurringTransaction.user_id == user_id
    ).delete(synchronize_session=False)

    # Finally delete the user record itself
    db.delete(user)
    db.commit()
    return {"status": "deleted"}


# ── APNs Device Token Registration ───────────────────────────────────────────

@app.post("/apns/register-device", status_code=204)
def apns_register_device(
    body: dict,
    db: Session = Depends(get_db),
    user_id: str = Depends(require_user_id),
):
    """Store (or update) an APNs device token for the authenticated user."""
    token   = (body.get("token") or "").strip()
    sandbox = bool(body.get("sandbox", False))
    if not token:
        raise HTTPException(status_code=400, detail="token required")
    existing = db.query(models.DeviceToken).filter(
        models.DeviceToken.token == token
    ).first()
    now_iso = datetime.now(timezone.utc).isoformat()
    if existing:
        existing.user_id    = user_id
        existing.sandbox    = sandbox
        existing.updated_at = now_iso
    else:
        db.add(models.DeviceToken(
            id=str(uuid4()), user_id=user_id,
            token=token, sandbox=sandbox, updated_at=now_iso,
        ))
    db.commit()


@app.delete("/apns/unregister-device", status_code=204)
def apns_unregister_device(
    body: dict,
    db: Session = Depends(get_db),
    user_id: str = Depends(require_user_id),
):
    """Remove an APNs device token (called on sign-out or when permissions revoked)."""
    token = (body.get("token") or "").strip()
    q = db.query(models.DeviceToken).filter(models.DeviceToken.user_id == user_id)
    if token:
        q = q.filter(models.DeviceToken.token == token)
    q.delete(synchronize_session=False)
    db.commit()


@app.delete("/user/transactions")
def user_clear_transactions(user_id: str = Depends(require_user_id), db: Session = Depends(get_db)):
    """Clear all transaction records for the current user. Accounts, wallets, holdings are kept."""
    account_ids = [a.id for a in db.query(models.Account).filter(models.Account.user_id == user_id).all()]
    if account_ids:
        # Collect event IDs tied to this user's legs
        leg_rows = db.query(models.TransactionLeg.event_id).filter(
            models.TransactionLeg.account_id.in_(account_ids)
        ).distinct().all()
        event_ids = [r.event_id for r in leg_rows]
        # Delete legs first (FK child), then events
        db.query(models.TransactionLeg).filter(
            models.TransactionLeg.account_id.in_(account_ids)
        ).delete(synchronize_session=False)
        if event_ids:
            db.query(models.TransactionEvent).filter(
                models.TransactionEvent.id.in_(event_ids)
            ).delete(synchronize_session=False)
    db.commit()
    return {"status": "ok"}

@app.delete("/user/data")
def user_full_reset(user_id: str = Depends(require_user_id), db: Session = Depends(get_db)):
    """Delete all accounts, holdings, transactions for the current user. User account is kept."""
    account_ids = [a.id for a in db.query(models.Account).filter(models.Account.user_id == user_id).all()]
    if account_ids:
        db.query(models.TransactionLeg).filter(
            models.TransactionLeg.account_id.in_(account_ids)
        ).delete(synchronize_session=False)
        db.query(models.Holding).filter(
            models.Holding.account_id.in_(account_ids)
        ).delete(synchronize_session=False)
        db.query(models.ExchangeConnection).filter(
            models.ExchangeConnection.account_id.in_(account_ids)
        ).delete(synchronize_session=False)
        db.query(models.BankConnection).filter(
            models.BankConnection.ledger_account_id.in_(account_ids)
        ).delete(synchronize_session=False)
        db.query(models.RecurringTransaction).filter(
            models.RecurringTransaction.from_account_id.in_(account_ids)
        ).delete(synchronize_session=False)
        db.query(models.Account).filter(
            models.Account.user_id == user_id
        ).delete(synchronize_session=False)
    # Clear watchlist for this user
    db.query(models.WatchlistItem).filter(
        models.WatchlistItem.user_id == user_id
    ).delete(synchronize_session=False)
    db.commit()
    return {"status": "ok"}

# ─────────────────────────────────────────────
# ROUTES
# ─────────────────────────────────────────────
@app.get("/")
def root():
    return {"status": "ok", "message": "LedgerVault API v4.1 — exchange sync enabled"}

@app.post("/reset")
def reset_database(admin_key: str = Query(...)):
    expected = os.getenv("ADMIN_KEY", "")
    if not expected or admin_key != expected:
        raise HTTPException(status_code=403, detail="Forbidden")
    # Drop + recreate ORM-managed tables
    Base.metadata.drop_all(bind=engine)
    Base.metadata.create_all(bind=engine)
    # Also clear raw-SQL tables (not managed by ORM so drop_all misses them)
    raw_tables = [
        "watchlist", "crypto_wallets",
        "snaptrade_connections", "vezgo_connections", "flanks_connections",
    ]
    with engine.connect() as conn:
        for tbl in raw_tables:
            try:
                conn.execute(text(f"DELETE FROM {tbl}"))
            except Exception:
                pass   # table may not exist yet on a fresh DB
        conn.commit()
    return {"status": "ok"}

@app.post("/reset/transactions")
def reset_transactions(admin_key: str = Query(...), db: Session = Depends(get_db)):
    expected = os.getenv("ADMIN_KEY", "")
    if not expected or admin_key != expected:
        raise HTTPException(status_code=403, detail="Forbidden")
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

def _all_profile_assigned_ids(user_id: str, db: Session) -> set:
    """Return every account ID that is assigned to at least one named profile."""
    profiles = db.query(models.AccountProfile).filter_by(user_id=user_id).all()
    assigned: set = set()
    for p in profiles:
        try:
            assigned.update(json.loads(p.account_ids or "[]"))
        except Exception:
            pass
    return assigned

def _profile_account_ids(profile_id: Optional[str], user_id: Optional[str],
                          all_user_ids: set, db: Session) -> Optional[set]:
    """
    Return the account ID set to use for a given profile_id.

    - profile_id = None  → 'Personal': all accounts that are NOT assigned to any
                           named profile (so Dad/Son accounts are excluded).
                           If no profiles exist yet, returns None (= all accounts,
                           keeping the feature backward-compatible for new users).
    - profile_id = <id>  → exactly the accounts in that named profile.
    """
    if not user_id:
        return None

    if not profile_id:
        # Personal: subtract accounts owned by named profiles
        assigned = _all_profile_assigned_ids(user_id, db)
        if not assigned:
            return None   # no profiles yet → show everything (backward-compat)
        return all_user_ids - assigned

    prof = db.query(models.AccountProfile).filter_by(id=profile_id, user_id=user_id).first()
    if not prof:
        # Unknown/unauthorised profile_id → show nothing (not None which shows everything)
        return set()
    try:
        ids = json.loads(prof.account_ids or "[]")
        return set(ids) if ids else set()
    except Exception:
        return set()

# ── Valuation ─────────────────────────────────
@app.get("/valuation")
def valuation(base_currency: str = "EUR", profile_id: Optional[str] = Query(None),
              db: Session = Depends(get_db),
              user_id: Optional[str] = Depends(get_user_id)):
    try: fx = _fetch_live_fx()
    except: fx = FALLBACK_FX

    crypto_prices = _fetch_crypto_prices()
    acct_q = db.query(models.Account)
    if user_id:
        acct_q = acct_q.filter(models.Account.user_id == user_id)
    else:
        acct_q = acct_q.filter(models.Account.user_id == None)
    all_accounts = {a.id: a for a in acct_q.all()}
    # Apply profile filter (Personal = exclude accounts owned by named profiles)
    profile_ids = _profile_account_ids(profile_id, user_id, set(all_accounts.keys()), db)
    accounts = {k: v for k, v in all_accounts.items() if profile_ids is None or k in profile_ids}

    # Empty profile (e.g. Dad/Son with no accounts assigned yet) — return zero immediately
    if not accounts:
        return {
            "base_currency":   base_currency.upper(),
            "total":           0.0,
            "cash":            0.0,
            "crypto":          0.0,
            "stocks":          0.0,
            "portfolio":       [],
            "recent_activity": [],
        }

    holdings  = db.query(models.Holding).filter(
        models.Holding.account_id.in_(accounts.keys())).all()
    assets    = {a.id: a for a in db.query(models.Asset).all()}

    # Build sym → quote_currency map so we can hint Yahoo Finance which exchange to prefer
    sym_to_quote_ccy: dict[str, str] = {
        assets[h.asset_id].symbol.upper(): (assets[h.asset_id].quote_currency or "USD")
        for h in holdings
        if h.asset_id in assets and assets[h.asset_id].asset_class in ("stock", "etf")
    }
    stock_symbols = set(sym_to_quote_ccy.keys())
    stock_prices: dict[str, dict] = {}   # sym → {price, currency}
    if stock_symbols:
        with ThreadPoolExecutor(max_workers=min(len(stock_symbols), 8)) as pool:
            futures = {pool.submit(_fetch_stock_price, sym, sym_to_quote_ccy.get(sym)): sym for sym in stock_symbols}
            for fut in as_completed(futures):
                sym = futures[fut]
                info = fut.result()
                if info:
                    stock_prices[sym] = {
                        "price": info["price"],
                        "currency": info.get("currency", "USD").upper()
                    }

    # Stablecoins are crypto assets that track fiat — count them in cash, not crypto
    STABLECOIN_SYMBOLS = {
        "USDT","USDC","BUSD","DAI","TUSD","USDP","FRAX","LUSD","PYUSD","FDUSD",
        "GUSD","PAX","USDD","CUSD","CEUR","EURS","USDE","SUSDE","USDBC","USDS",
        "EURC","EURT","XSGD","XIDR","CADC","BRLA","BIDR"
    }

    portfolio_items = []
    total_base = cash_total = crypto_total = stock_total = 0.0

    excluded_account_ids = {aid for aid, a in accounts.items() if a.exclude_from_total}

    for holding in holdings:
        asset   = assets.get(holding.asset_id)
        account = accounts.get(holding.account_id)
        if not asset or not account: continue

        sym = asset.symbol.upper()
        quote_ccy = (asset.quote_currency or "USD").upper()

        if asset.asset_class == "fiat":
            price_usd = fx.get(sym, 1.0)
            native_price = price_usd   # fiat price IS the USD price (via FX)
        elif asset.asset_class == "crypto":
            price_usd = crypto_prices.get(sym, 0.0)
            native_price = price_usd   # crypto quoted in USD
        elif asset.asset_class in ("stock","etf"):
            stock_info  = stock_prices.get(sym, {})
            native_price = stock_info.get("price", 0.0)
            # Use the ACTUAL currency Yahoo Finance returned (may differ from asset.quote_currency)
            actual_ccy  = stock_info.get("currency", quote_ccy)
            if actual_ccy == "GBp":   # Yahoo sometimes returns pence
                native_price /= 100.0
                actual_ccy = "GBP"
            # Convert actual native price to USD for consistent portfolio math
            if actual_ccy != "USD" and actual_ccy in fx:
                price_usd = native_price * fx.get(actual_ccy, 1.0)
            else:
                price_usd = native_price
        else:
            price_usd    = 0.0
            native_price = 0.0

        value_usd  = holding.quantity * price_usd
        value_base = convert_usd_to_base(value_usd, base_currency, fx)

        # Convert avg_cost to USD (avg_cost is stored in quote_currency)
        if quote_ccy == "USD" or asset.asset_class == "fiat":
            avg_cost_usd = holding.avg_cost
        else:
            # fx[quote_ccy] = how many USD per 1 unit of quote_ccy
            avg_cost_usd = holding.avg_cost * fx.get(quote_ccy, 1.0)
        cost_usd  = holding.quantity * avg_cost_usd
        cost_base = convert_usd_to_base(cost_usd, base_currency, fx)

        portfolio_items.append({
            "holding_id":    holding.id,
            "account_id":    account.id,
            "account_name":  account.name,
            "asset_id":      asset.id,
            "symbol":        asset.symbol,
            "asset_name":    asset.name,
            "asset_class":   asset.asset_class,
            "quote_currency":asset.quote_currency,
            "quantity":      holding.quantity,
            "avg_cost":      holding.avg_cost,
            "price_usd":     price_usd,       # always USD-equivalent
            "native_price":  native_price,    # price in asset's quote_currency (for display)
            "value_in_base": round(value_base, 2),
            "cost_in_base":  round(cost_base, 2),
            "base_currency": base_currency.upper(),
        })

        if account.id not in excluded_account_ids:
            total_base += value_base
            is_stablecoin = asset.asset_class == "crypto" and sym in STABLECOIN_SYMBOLS
            if asset.asset_class == "fiat" or is_stablecoin:
                cash_total   += value_base
            elif asset.asset_class == "crypto" and not is_stablecoin:
                crypto_total += value_base
            elif asset.asset_class in ("stock","etf"):
                stock_total  += value_base

    user_leg_event_ids = [r[0] for r in db.query(models.TransactionLeg.event_id)
        .filter(models.TransactionLeg.account_id.in_(accounts.keys())).distinct().all()]
    recent_events = (
        db.query(models.TransactionEvent)
        .filter(models.TransactionEvent.id.in_(user_leg_event_ids))
        .order_by(models.TransactionEvent.date.desc(),
                  models.TransactionEvent.created_at.desc())
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
             "description": e.description, "date": e.date, "note": e.note,
             "created_at": e.created_at}
            for e in recent_events
        ],
    }

# ── Portfolio History ─────────────────────────
# Returns daily total portfolio value for the past N days (uses current holdings × historical prices)
_hist_cache: dict = {"ts": 0, "key": "", "data": None}
HIST_CACHE_TTL = 3600  # 1 hour

@app.get("/portfolio/history")
def portfolio_history(days: int = 30, base_currency: str = "EUR",
                      profile_id: Optional[str] = Query(None),
                      db: Session = Depends(get_db),
                      user_id: Optional[str] = Depends(get_user_id)):
    # Include leg count in key so cache busts automatically when holdings change
    leg_count = db.query(_sqlfunc.count(models.TransactionLeg.id)).scalar() or 0
    cache_key = f"{days}:{base_currency.upper()}:{user_id or ''}:{profile_id or ''}:{leg_count}"
    # 1D cache is shorter (5 min) since intraday data changes frequently
    ttl = 300 if days == 1 else HIST_CACHE_TTL
    if _hist_cache["key"] == cache_key and (time.time() - _hist_cache["ts"]) < ttl:
        return _hist_cache["data"]

    from datetime import date as date_type
    today = date_type.today()
    intraday = (days == 1)   # special hourly mode

    if intraday:
        # Generate hourly slots from 00:00 to the current hour (UTC)
        now_utc = datetime.now(timezone.utc)
        slots = [f"{h:02d}:00" for h in range(now_utc.hour + 1)]
    else:
        dates = [(today - timedelta(days=i)).isoformat() for i in range(days - 1, -1, -1)]

    acct_q = db.query(models.Account)
    if user_id:
        acct_q = acct_q.filter(models.Account.user_id == user_id)
    else:
        acct_q = acct_q.filter(models.Account.user_id == None)
    all_ids = {a.id for a in acct_q.all()}
    profile_filter = _profile_account_ids(profile_id, user_id, all_ids, db)
    user_account_ids = all_ids if profile_filter is None else all_ids & profile_filter

    holdings = db.query(models.Holding).filter(
        _sqlfunc.abs(models.Holding.quantity) > 0.000001,   # include negative (offset/liability accounts)
        models.Holding.account_id.in_(user_account_ids)).all()
    assets   = {a.id: a for a in db.query(models.Asset).all()}

    try: fx = _fetch_live_fx()
    except: fx = FALLBACK_FX

    # -- Build price_history: {symbol: {date_str: price_usd}} --
    price_history: dict[str, dict[str, float]] = {}

    crypto_syms = list({assets[h.asset_id].symbol.upper()
                        for h in holdings
                        if h.asset_id in assets and assets[h.asset_id].asset_class == "crypto"})
    stock_syms  = list({assets[h.asset_id].symbol.upper()
                        for h in holdings
                        if h.asset_id in assets
                        and assets[h.asset_id].asset_class in ("stock", "etf")})

    # Crypto history via CoinGecko
    if crypto_syms:
        try:
            markets_url = "https://api.coingecko.com/api/v3/coins/markets?vs_currency=usd&per_page=250&page=1"
            with httpx.Client(timeout=10.0) as c:
                r = c.get(markets_url); r.raise_for_status()
            sym_to_id = {coin["symbol"].upper(): coin["id"] for coin in r.json()}
            for sym in crypto_syms:
                cg_id = sym_to_id.get(sym)
                if not cg_id:
                    continue
                try:
                    if intraday:
                        # days=1 → CoinGecko returns 5-min intervals automatically
                        hist_url = (f"https://api.coingecko.com/api/v3/coins/{cg_id}"
                                    f"/market_chart?vs_currency=usd&days=1")
                        with httpx.Client(timeout=10.0) as c:
                            r = c.get(hist_url); r.raise_for_status()
                        price_history[sym] = {}
                        for ts_ms, price in r.json().get("prices", []):
                            dt = datetime.fromtimestamp(ts_ms / 1000, tz=timezone.utc)
                            # Keep most-recent price per hour slot
                            slot = f"{dt.hour:02d}:00"
                            price_history[sym][slot] = float(price)
                    else:
                        hist_url = (f"https://api.coingecko.com/api/v3/coins/{cg_id}"
                                    f"/market_chart?vs_currency=usd&days={days}&interval=daily")
                        with httpx.Client(timeout=10.0) as c:
                            r = c.get(hist_url); r.raise_for_status()
                        price_history[sym] = {}
                        for ts_ms, price in r.json().get("prices", []):
                            d = datetime.fromtimestamp(ts_ms / 1000, tz=timezone.utc).date().isoformat()
                            price_history[sym][d] = float(price)
                except Exception as e:
                    logger.warning(f"CoinGecko history failed for {sym}: {e}")
        except Exception as e:
            logger.warning(f"CoinGecko markets for history failed: {e}")

    # Stock history via Yahoo Finance
    def _fetch_stock_history(sym: str) -> tuple[str, dict[str, float]]:
        if intraday:
            url = (f"https://query1.finance.yahoo.com/v8/finance/chart/{sym}"
                   f"?interval=1h&range=1d")
        else:
            yf_range = f"{min(days, 365)}d"
            url = (f"https://query1.finance.yahoo.com/v8/finance/chart/{sym}"
                   f"?interval=1d&range={yf_range}")
        try:
            with httpx.Client(timeout=8.0, headers={"User-Agent": "Mozilla/5.0"}) as c:
                r = c.get(url); r.raise_for_status()
            result = r.json()["chart"]["result"][0]
            timestamps = result.get("timestamp", [])
            closes = result["indicators"]["quote"][0].get("close", [])
            hist = {}
            for ts, close in zip(timestamps, closes):
                if close is not None:
                    if intraday:
                        dt = datetime.fromtimestamp(ts, tz=timezone.utc)
                        slot = f"{dt.hour:02d}:00"
                        hist[slot] = float(close)
                    else:
                        d = datetime.fromtimestamp(ts, tz=timezone.utc).date().isoformat()
                        hist[d] = float(close)
            return sym, hist
        except Exception as e:
            logger.warning(f"Yahoo history failed for {sym}: {e}")
            return sym, {}

    if stock_syms:
        with ThreadPoolExecutor(max_workers=min(len(stock_syms), 8)) as pool:
            for sym, hist in pool.map(_fetch_stock_history, stock_syms):
                if hist:
                    price_history[sym] = hist

    # -- Compute totals per slot (hourly for 1D, daily otherwise) --
    # avg_cost fallback: when no historical price exists for a slot (e.g. pre-market
    # for intraday, or before a holding was added), use the holding's avg_cost instead
    # of 0.  This means newly-imported holdings contribute their cost basis to all
    # earlier slots, so an import mid-day never appears as a "profit spike".
    def _get_price(sym: str, slot: str, cost_basis_fallback: float = 0.0) -> float:
        hist = price_history.get(sym)
        if not hist:
            # No price history at all → treat as if held at cost basis
            return cost_basis_fallback
        if slot in hist:
            return hist[slot]
        # Fall back to most-recent available price before this slot
        past = sorted(d for d in hist if d <= slot)
        if past:
            return hist[past[-1]]
        # No data before this slot (e.g. pre-market hours) → use cost basis
        return cost_basis_fallback

    points = []
    slot_list = slots if intraday else dates
    for slot in slot_list:
        total = 0.0
        for holding in holdings:
            asset = assets.get(holding.asset_id)
            if not asset or abs(holding.quantity) <= 0.000001:
                continue
            sym       = asset.symbol.upper()
            quote_ccy = (asset.quote_currency or "USD").upper()
            if asset.asset_class == "fiat":
                price_usd = fx.get(sym, 1.0)
            elif asset.asset_class in ("crypto", "stock", "etf"):
                # avg_cost is stored in quote_currency (USD for most crypto/stocks,
                # EUR for VUSA.AS etc.) — convert to USD before using as fallback
                # so pre-market / no-history slots show the true cost basis, not zero.
                avg_cost_usd = (holding.avg_cost or 0.0) * fx.get(quote_ccy, 1.0)
                price_usd = _get_price(sym, slot, avg_cost_usd)
            else:
                price_usd = 0.0
            value_usd = holding.quantity * price_usd
            total += convert_usd_to_base(value_usd, base_currency, fx)
        points.append({"date": slot, "total": round(total, 2)})

    # Total cost basis in base currency — used by the app to show true P&L
    # (current_value - cost_basis) so imports never register as profit/loss.
    cost_basis = 0.0
    for holding in holdings:
        asset = assets.get(holding.asset_id)
        if not asset or abs(holding.quantity) <= 0.000001:
            continue
        sym       = asset.symbol.upper()
        quote_ccy = (asset.quote_currency or "USD").upper()
        if asset.asset_class == "fiat":
            cost_usd = holding.quantity * fx.get(sym, 1.0)
        elif quote_ccy == "USD":
            cost_usd = holding.quantity * (holding.avg_cost or 0.0)
        else:
            cost_usd = holding.quantity * (holding.avg_cost or 0.0) * fx.get(quote_ccy, 1.0)
        cost_basis += convert_usd_to_base(cost_usd, base_currency, fx)

    result = {
        "base_currency": base_currency.upper(),
        "days":          days,
        "points":        points,
        "cost_basis":    round(cost_basis, 2),
    }
    _hist_cache.update({"ts": time.time(), "key": cache_key, "data": result})
    return result

# ── Accounts ──────────────────────────────────
@app.get("/accounts", response_model=AccountList)
def list_accounts(db: Session = Depends(get_db), user_id: Optional[str] = Depends(get_user_id)):
    q = db.query(models.Account)
    if user_id:
        q = q.filter(models.Account.user_id == user_id)
    else:
        q = q.filter(models.Account.user_id == None)
    return {"items": q.all()}

@app.post("/accounts", response_model=AccountOut)
def create_account(payload: AccountCreate, db: Session = Depends(get_db),
                   user_id: Optional[str] = Depends(get_user_id)):
    item = models.Account(id=str(uuid4()), name=payload.name,
                          account_type=payload.account_type,
                          base_currency=normalize_base_currency(payload.base_currency),
                          exclude_from_total=payload.exclude_from_total,
                          user_id=user_id)
    db.add(item); db.commit(); db.refresh(item); return item

@app.post("/accounts/fix-base-currencies")
def fix_account_base_currencies(db: Session = Depends(get_db),
                                 user_id: str = Depends(require_user_id)):
    """One-shot: normalise stablecoin base_currency values (e.g. USDC→USD, USDT→USD)
    for all accounts belonging to the current user."""
    accounts = db.query(models.Account).filter(models.Account.user_id == user_id).all()
    fixed = []
    for acc in accounts:
        normalized = normalize_base_currency(acc.base_currency)
        if normalized != acc.base_currency:
            fixed.append({"id": acc.id, "name": acc.name,
                           "old": acc.base_currency, "new": normalized})
            acc.base_currency = normalized
    db.commit()
    return {"fixed": len(fixed), "accounts": fixed}

@app.put("/accounts/{account_id}", response_model=AccountOut)
def update_account(account_id: str, payload: AccountUpdate, db: Session = Depends(get_db),
                   user_id: str = Depends(require_user_id)):
    item = db.query(models.Account).filter(models.Account.id == account_id).first()
    if not item: raise HTTPException(status_code=404, detail="Account not found")
    if item.user_id != user_id: raise HTTPException(status_code=403, detail="Forbidden")
    if payload.name is not None:               item.name               = payload.name
    if payload.account_type is not None:       item.account_type       = payload.account_type
    if payload.base_currency is not None:      item.base_currency      = normalize_base_currency(payload.base_currency)
    if payload.exclude_from_total is not None: item.exclude_from_total = payload.exclude_from_total
    db.commit(); db.refresh(item); return item

@app.get("/accounts/{account_id}/holdings", response_model=HoldingList)
def list_account_holdings(account_id: str, db: Session = Depends(get_db),
                          user_id: str = Depends(require_user_id)):
    account = db.query(models.Account).filter(models.Account.id == account_id).first()
    if not account:
        raise HTTPException(status_code=404, detail="Account not found")
    if account.user_id and account.user_id != user_id:
        raise HTTPException(status_code=403, detail="Forbidden")
    return {"items": db.query(models.Holding).filter(models.Holding.account_id == account_id).all()}

@app.get("/accounts/{account_id}/transactions", response_model=TransactionEventList)
def list_account_transactions(account_id: str, db: Session = Depends(get_db),
                               user_id: str = Depends(require_user_id)):
    account = db.query(models.Account).filter(models.Account.id == account_id).first()
    if not account:
        raise HTTPException(status_code=404, detail="Account not found")
    if account.user_id and account.user_id != user_id:
        raise HTTPException(status_code=403, detail="Forbidden")
    ids = [r[0] for r in db.query(models.TransactionLeg.event_id)
           .filter(models.TransactionLeg.account_id == account_id).distinct().all()]
    items = (db.query(models.TransactionEvent)
             .filter(models.TransactionEvent.id.in_(ids))
             .order_by(models.TransactionEvent.date.desc()).all())
    return {"items": items}

@app.delete("/accounts/{account_id}")
def delete_account(account_id: str, db: Session = Depends(get_db),
                   user_id: str = Depends(require_user_id)):
    item = db.query(models.Account).filter(models.Account.id == account_id).first()
    if not item: raise HTTPException(status_code=404, detail="Account not found")
    if item.user_id != user_id: raise HTTPException(status_code=403, detail="Forbidden")
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
def list_holdings(db: Session = Depends(get_db), user_id: Optional[str] = Depends(get_user_id)):
    acct_q = db.query(models.Account)
    if user_id:
        acct_q = acct_q.filter(models.Account.user_id == user_id)
    else:
        acct_q = acct_q.filter(models.Account.user_id == None)
    user_account_ids = [a.id for a in acct_q.all()]
    return {"items": db.query(models.Holding).filter(
        models.Holding.account_id.in_(user_account_ids)).all()}

# ── Transaction events ────────────────────────
@app.get("/transaction-events", response_model=TransactionEventList)
def list_transaction_events(account_id: str = Query(None), db: Session = Depends(get_db),
                             user_id: Optional[str] = Depends(get_user_id)):
    acct_q = db.query(models.Account)
    if user_id:
        acct_q = acct_q.filter(models.Account.user_id == user_id)
    else:
        acct_q = acct_q.filter(models.Account.user_id == None)
    user_account_ids = {a.id for a in acct_q.all()}

    filter_ids = [account_id] if account_id and account_id in user_account_ids else list(user_account_ids)
    ids = [r[0] for r in db.query(models.TransactionLeg.event_id)
           .filter(models.TransactionLeg.account_id.in_(filter_ids)).distinct().all()]
    items = (db.query(models.TransactionEvent)
             .filter(models.TransactionEvent.id.in_(ids))
             .order_by(models.TransactionEvent.date.desc(),
                       models.TransactionEvent.created_at.desc()).all())
    return {"items": items}

@app.get("/transaction-legs", response_model=TransactionLegList)
def list_transaction_legs(db: Session = Depends(get_db), user_id: Optional[str] = Depends(get_user_id)):
    acct_q = db.query(models.Account)
    if user_id:
        acct_q = acct_q.filter(models.Account.user_id == user_id)
    else:
        acct_q = acct_q.filter(models.Account.user_id == None)
    user_account_ids = [a.id for a in acct_q.all()]
    return {"items": db.query(models.TransactionLeg).filter(
        models.TransactionLeg.account_id.in_(user_account_ids)).all()}

@app.put("/holdings/{holding_id}")
def update_holding(holding_id: str, payload: dict, db: Session = Depends(get_db),
                   user_id: str = Depends(require_user_id)):
    """Directly update a holding's quantity and/or avg_cost (for manual corrections)."""
    holding = db.query(models.Holding).filter(models.Holding.id == holding_id).first()
    if not holding:
        raise HTTPException(status_code=404, detail="Holding not found")
    acct = db.query(models.Account).filter(
        models.Account.id == holding.account_id,
        models.Account.user_id == user_id).first()
    if not acct:
        raise HTTPException(status_code=403, detail="Forbidden")
    if "quantity" in payload and payload["quantity"] is not None:
        holding.quantity = float(payload["quantity"])
    if "avg_cost" in payload and payload["avg_cost"] is not None:
        holding.avg_cost = float(payload["avg_cost"])
    db.commit(); db.refresh(holding)
    return {"id": holding.id, "account_id": holding.account_id, "asset_id": holding.asset_id,
            "quantity": holding.quantity, "avg_cost": holding.avg_cost}

@app.delete("/holdings/{holding_id}")
def delete_holding(holding_id: str, db: Session = Depends(get_db),
                   user_id: str = Depends(require_user_id)):
    """Delete a holding and all its associated transaction legs/events."""
    holding = db.query(models.Holding).filter(models.Holding.id == holding_id).first()
    if not holding:
        raise HTTPException(status_code=404, detail="Holding not found")
    acct = db.query(models.Account).filter(
        models.Account.id == holding.account_id,
        models.Account.user_id == user_id).first()
    if not acct:
        raise HTTPException(status_code=403, detail="Forbidden")
    # Find all event_ids whose legs touch this holding (account + asset)
    event_ids = [r[0] for r in db.query(models.TransactionLeg.event_id).filter(
        models.TransactionLeg.account_id == holding.account_id,
        models.TransactionLeg.asset_id == holding.asset_id).distinct().all()]
    for eid in event_ids:
        legs = db.query(models.TransactionLeg).filter(models.TransactionLeg.event_id == eid).all()
        for leg in legs:
            db.delete(leg)
        event = db.query(models.TransactionEvent).filter(models.TransactionEvent.id == eid).first()
        if event:
            db.delete(event)
    db.delete(holding)
    db.commit()
    return {"ok": True}

@app.put("/transaction-events/{event_id}", response_model=TransactionEventOut)
def update_transaction_event(event_id: str, payload: TransactionEventUpdate, db: Session = Depends(get_db),
                              user_id: str = Depends(require_user_id)):
    event = db.query(models.TransactionEvent).filter(
        models.TransactionEvent.id == event_id).first()
    if not event:
        raise HTTPException(status_code=404, detail="Event not found")
    # Verify the event belongs to this user via transaction legs
    user_acct_ids = {a.id for a in db.query(models.Account).filter(models.Account.user_id == user_id).all()}
    event_acct_ids = {l.account_id for l in db.query(models.TransactionLeg).filter(
        models.TransactionLeg.event_id == event_id).all()}
    if not event_acct_ids.intersection(user_acct_ids):
        raise HTTPException(status_code=403, detail="Forbidden")
    if payload.event_type is not None:  event.event_type  = payload.event_type
    if payload.category is not None:    event.category    = payload.category
    if payload.description is not None: event.description = payload.description
    if payload.date is not None:        event.date        = payload.date
    if payload.note is not None:        event.note        = payload.note
    db.commit(); db.refresh(event)
    return event

@app.delete("/transaction-events/{event_id}")
def delete_transaction_event(event_id: str, db: Session = Depends(get_db),
                              user_id: str = Depends(require_user_id)):
    try:
        event = db.query(models.TransactionEvent).filter(
            models.TransactionEvent.id == event_id).first()
        if not event: raise HTTPException(status_code=404, detail="Event not found")
        # Verify ownership via legs
        user_acct_ids = {a.id for a in db.query(models.Account).filter(models.Account.user_id == user_id).all()}
        event_acct_ids = {l.account_id for l in db.query(models.TransactionLeg).filter(
            models.TransactionLeg.event_id == event_id).all()}
        if not event_acct_ids.intersection(user_acct_ids):
            raise HTTPException(status_code=403, detail="Forbidden")
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
        created_at=datetime.now(timezone.utc).isoformat(),
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

# ── Account Profiles ───────────────────────────

def _profile_out(p: models.AccountProfile) -> AccountProfileOut:
    try:
        ids = json.loads(p.account_ids or "[]")
    except Exception:
        ids = []
    return AccountProfileOut(
        id=p.id, name=p.name,
        emoji=p.emoji or "👤",
        account_ids=ids,
        sort_order=int(p.sort_order) if p.sort_order else 0,
    )

@app.get("/profiles", response_model=AccountProfileList)
def list_profiles(user_id: str = Depends(require_user_id), db: Session = Depends(get_db)):
    profiles = db.query(models.AccountProfile).filter_by(user_id=user_id).all()
    return {"items": [_profile_out(p) for p in profiles]}

@app.post("/profiles", response_model=AccountProfileOut)
def create_profile(payload: AccountProfileCreate, user_id: str = Depends(require_user_id),
                   db: Session = Depends(get_db)):
    prof = models.AccountProfile(
        id=str(uuid4()), user_id=user_id,
        name=payload.name.strip(), emoji=payload.emoji,
        account_ids=json.dumps(payload.account_ids),
        sort_order="0",
        created_at=datetime.now(timezone.utc).isoformat(),
    )
    db.add(prof); db.commit(); db.refresh(prof)
    return _profile_out(prof)

@app.put("/profiles/{profile_id}", response_model=AccountProfileOut)
def update_profile(profile_id: str, payload: AccountProfileUpdate,
                   user_id: str = Depends(require_user_id), db: Session = Depends(get_db)):
    prof = db.query(models.AccountProfile).filter_by(id=profile_id, user_id=user_id).first()
    if not prof:
        raise HTTPException(404, "Profile not found")
    if payload.name is not None:        prof.name        = payload.name.strip()
    if payload.emoji is not None:       prof.emoji       = payload.emoji
    if payload.account_ids is not None: prof.account_ids = json.dumps(payload.account_ids)
    if payload.sort_order is not None:  prof.sort_order  = str(payload.sort_order)
    db.commit(); db.refresh(prof)
    return _profile_out(prof)

@app.delete("/profiles/{profile_id}")
def delete_profile(profile_id: str, user_id: str = Depends(require_user_id),
                   db: Session = Depends(get_db)):
    prof = db.query(models.AccountProfile).filter_by(id=profile_id, user_id=user_id).first()
    if not prof:
        raise HTTPException(404, "Profile not found")
    db.delete(prof); db.commit()
    return {"status": "ok"}

# ── Exchange Connections ───────────────────────
@app.get("/exchange-connections", response_model=ExchangeConnectionList)
def list_exchange_connections(db: Session = Depends(get_db),
                               user_id: str = Depends(require_user_id)):
    items = db.query(models.ExchangeConnection).filter(
        models.ExchangeConnection.user_id == user_id).all()
    result = []
    for c in items:
        raw_key = _decrypt(c.api_key)
        masked = ("*" * (len(raw_key) - 4) + raw_key[-4:]) if len(raw_key) >= 4 else "****"
        result.append(ExchangeConnectionOut(
            id=c.id, exchange=c.exchange, name=c.name,
            api_key_masked=masked, account_id=c.account_id,
            last_synced=c.last_synced, status=c.status,
            status_message=c.status_message,
        ))
    return {"items": result}

@app.post("/exchange-connections", response_model=ExchangeConnectionOut)
def create_exchange_connection(payload: ExchangeConnectionCreate, db: Session = Depends(get_db),
                                user_id: str = Depends(require_user_id)):
    conn = models.ExchangeConnection(
        id=str(uuid4()), user_id=user_id, exchange=payload.exchange, name=payload.name,
        api_key=_encrypt(payload.api_key), api_secret=_encrypt(payload.api_secret),
        passphrase=_encrypt(payload.passphrase) if payload.passphrase else None,
        account_id=payload.account_id, status="active",
    )
    db.add(conn); db.commit(); db.refresh(conn)
    raw_key = _decrypt(conn.api_key)
    masked = ("*" * (len(raw_key) - 4) + raw_key[-4:]) if len(raw_key) >= 4 else "****"
    return ExchangeConnectionOut(
        id=conn.id, exchange=conn.exchange, name=conn.name,
        api_key_masked=masked, account_id=conn.account_id,
        last_synced=conn.last_synced, status=conn.status,
        status_message=conn.status_message,
    )

@app.delete("/exchange-connections/{connection_id}")
def delete_exchange_connection(connection_id: str, db: Session = Depends(get_db),
                                user_id: str = Depends(require_user_id)):
    conn = db.query(models.ExchangeConnection).filter(
        models.ExchangeConnection.id == connection_id).first()
    if not conn:
        raise HTTPException(status_code=404, detail="Connection not found")
    if conn.user_id and conn.user_id != user_id:
        raise HTTPException(status_code=403, detail="Forbidden")
    db.delete(conn); db.commit()
    return {"status": "ok"}

@app.post("/exchange-connections/{connection_id}/sync", response_model=SyncResult)
def sync_exchange_connection(connection_id: str, db: Session = Depends(get_db),
                              user_id: str = Depends(require_user_id)):
    conn = db.query(models.ExchangeConnection).filter(
        models.ExchangeConnection.id == connection_id).first()
    if not conn:
        raise HTTPException(status_code=404, detail="Connection not found")
    if conn.user_id and conn.user_id != user_id:
        raise HTTPException(status_code=403, detail="Forbidden")

    # Decrypt credentials before passing to sync functions
    conn.api_key    = _decrypt(conn.api_key)
    conn.api_secret = _decrypt(conn.api_secret)
    if conn.passphrase:
        conn.passphrase = _decrypt(conn.passphrase)

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
def list_recurring_transactions(db: Session = Depends(get_db),
                                 user_id: str = Depends(require_user_id)):
    return {"items": db.query(models.RecurringTransaction).filter(
        models.RecurringTransaction.user_id == user_id).all()}

@app.post("/recurring-transactions", response_model=RecurringTransactionOut)
def create_recurring_transaction(payload: RecurringTransactionCreate, db: Session = Depends(get_db),
                                  user_id: str = Depends(require_user_id)):
    item = models.RecurringTransaction(
        id=str(uuid4()),
        user_id=user_id,
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
                                  db: Session = Depends(get_db),
                                  user_id: str = Depends(require_user_id)):
    item = db.query(models.RecurringTransaction).filter(
        models.RecurringTransaction.id == rt_id).first()
    if not item:
        raise HTTPException(status_code=404, detail="Not found")
    if item.user_id and item.user_id != user_id:
        raise HTTPException(status_code=403, detail="Forbidden")
    for field, value in payload.dict(exclude_none=True).items():
        setattr(item, field, value)
    db.commit(); db.refresh(item); return item

@app.delete("/recurring-transactions/{rt_id}")
def delete_recurring_transaction(rt_id: str, db: Session = Depends(get_db),
                                  user_id: str = Depends(require_user_id)):
    item = db.query(models.RecurringTransaction).filter(
        models.RecurringTransaction.id == rt_id).first()
    if not item:
        raise HTTPException(status_code=404, detail="Not found")
    if item.user_id and item.user_id != user_id:
        raise HTTPException(status_code=403, detail="Forbidden")
    db.delete(item); db.commit()
    return {"status": "ok"}

@app.get("/spending/summary")
def spending_summary(
    year: int = Query(None), month: int = Query(None),
    base_currency: str = "EUR",
    profile_id: Optional[str] = Query(None),
    db: Session = Depends(get_db),
    user_id: Optional[str] = Depends(get_user_id)
):
    """Monthly spending/income breakdown by category."""
    now = datetime.now()
    y = year or now.year
    m = month or now.month
    start = f"{y:04d}-{m:02d}-01"
    # last day of month
    if m == 12:
        end = f"{y+1:04d}-01-01"
    else:
        end = f"{y:04d}-{m+1:02d}-01"

    events_q = db.query(models.TransactionEvent).filter(
        models.TransactionEvent.date >= start,
        models.TransactionEvent.date < end
    )
    # profile filter via account ownership
    account_ids = None
    if profile_id or user_id:
        acct_q = db.query(models.Account)
        if profile_id:
            acct_q = acct_q.filter(models.Account.profile_id == profile_id)
        elif user_id:
            acct_q = acct_q.filter(models.Account.user_id == user_id)
        account_ids = {a.id for a in acct_q.all()}

    fx = _get_fx_rates()
    income_by_cat: dict = {}
    expense_by_cat: dict = {}

    for event in events_q.all():
        et = event.event_type.lower()
        if et not in ("income", "expense"):
            continue
        # check account filter
        legs = db.query(models.TransactionLeg).filter(
            models.TransactionLeg.event_id == event.id,
            models.TransactionLeg.fee_flag != "true"
        ).all()
        if account_ids is not None:
            if not any(leg.account_id in account_ids for leg in legs):
                continue
        # sum absolute value in base_currency
        total = 0.0
        for leg in legs:
            qty = abs(leg.quantity)
            if qty == 0:
                continue
            asset = db.query(models.Asset).filter(models.Asset.id == leg.asset_id).first() if leg.asset_id else None
            symbol = asset.symbol.upper() if asset else base_currency.upper()
            usd_val = qty * (fx.get(symbol, 1.0))
            base_usd = fx.get(base_currency.upper(), 1.0)
            total += usd_val / base_usd if base_usd else usd_val
        cat = event.category or ("Salary" if et == "income" else "Other")
        if et == "income":
            income_by_cat[cat] = income_by_cat.get(cat, 0.0) + total
        else:
            expense_by_cat[cat] = expense_by_cat.get(cat, 0.0) + total

    return {
        "year": y, "month": m, "base_currency": base_currency,
        "income": [{"category": k, "amount": round(v, 2)} for k, v in sorted(income_by_cat.items(), key=lambda x: -x[1])],
        "expenses": [{"category": k, "amount": round(v, 2)} for k, v in sorted(expense_by_cat.items(), key=lambda x: -x[1])],
        "total_income": round(sum(income_by_cat.values()), 2),
        "total_expenses": round(sum(expense_by_cat.values()), 2),
    }

@app.post("/recurring-transactions/{rt_id}/execute")
def execute_recurring_transaction(rt_id: str, db: Session = Depends(get_db),
                                   user_id: str = Depends(require_user_id)):
    """Manually execute a recurring transaction now."""
    item = db.query(models.RecurringTransaction).filter(
        models.RecurringTransaction.id == rt_id).first()
    if not item:
        raise HTTPException(status_code=404, detail="Not found")
    if item.user_id and item.user_id != user_id:
        raise HTTPException(status_code=403, detail="Forbidden")

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
def seed_data(admin_key: str = Query(...), db: Session = Depends(get_db)):
    expected = os.getenv("ADMIN_KEY", "")
    if not expected or admin_key != expected:
        raise HTTPException(status_code=403, detail="Forbidden")
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
    raw_access  = _decrypt(conn.access_token)
    raw_refresh = _decrypt(conn.refresh_token) if conn.refresh_token else None
    if not raw_refresh:
        return raw_access
    try:
        with httpx.Client(timeout=10) as c:
            r = c.post(f"{TRUELAYER_AUTH_URL}/connect/token", data={
                "grant_type":    "refresh_token",
                "client_id":     TRUELAYER_CLIENT_ID,
                "client_secret": TRUELAYER_CLIENT_SECRET,
                "refresh_token": raw_refresh,
            })
            if r.status_code == 200:
                tokens = r.json()
                new_access  = tokens["access_token"]
                new_refresh = tokens.get("refresh_token", raw_refresh)
                conn.access_token  = _encrypt(new_access)
                conn.refresh_token = _encrypt(new_refresh)
                db.commit()
                return new_access
    except Exception:
        pass
    return raw_access


@app.get("/bank-connections/auth-url", response_model=BankAuthUrlResponse)
def bank_auth_url():
    """Generate a TrueLayer OAuth URL for the iOS app to open."""
    import secrets
    state = secrets.token_urlsafe(16)
    # Use quote (not urlencode) so spaces encode as %20 — TrueLayer requires this
    # offline_access → get a refresh token so we can re-auth silently later
    scope        = urllib.parse.quote("info accounts balance cards transactions direct_debits standing_orders offline_access")
    redirect_uri = urllib.parse.quote(TRUELAYER_REDIRECT_URI, safe="")
    providers    = urllib.parse.quote("uk-cs-mock uk-ob-all uk-oauth-all")
    url = (
        f"{TRUELAYER_AUTH_URL}/"
        f"?response_type=code"
        f"&client_id={TRUELAYER_CLIENT_ID}"
        f"&scope={scope}"
        f"&redirect_uri={redirect_uri}"
        f"&providers={providers}"
        f"&state={state}"
        f"&nonce={state}"
        f"&enable_mock=true"
    )
    return {"auth_url": url, "state": state}


@app.post("/bank-connections/callback", response_model=BankCallbackResponse)
def bank_callback(code: str = Query(...), db: Session = Depends(get_db),
                  user_id: Optional[str] = Depends(get_user_id)):
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
            existing.access_token  = _encrypt(access_token)
            existing.refresh_token = _encrypt(refresh_token)
            existing.status        = "active"
            created.append(existing)
            continue

        conn = models.BankConnection(
            id=str(uuid4()),
            user_id=user_id,
            provider_id=provider_id,
            provider_name=provider_name,
            account_display_name=tl_acct.get("display_name", "Account"),
            account_type=tl_acct.get("account_type", "TRANSACTION"),
            currency=tl_acct.get("currency", "GBP"),
            truelayer_account_id=tl_id,
            access_token=_encrypt(access_token),
            refresh_token=_encrypt(refresh_token),
            status="active",
        )
        db.add(conn)
        created.append(conn)

    db.commit()
    return {"items": [_tl_conn_out(c) for c in created]}


@app.get("/bank-connections", response_model=BankConnectionList)
def list_bank_connections(db: Session = Depends(get_db),
                          user_id: str = Depends(require_user_id)):
    conns = db.query(models.BankConnection).filter(
        models.BankConnection.user_id == user_id).all()
    return {"items": [_tl_conn_out(c) for c in conns]}


@app.delete("/bank-connections/{conn_id}")
def delete_bank_connection(conn_id: str, db: Session = Depends(get_db),
                            user_id: str = Depends(require_user_id)):
    conn = db.query(models.BankConnection).filter_by(id=conn_id).first()
    if not conn:
        raise HTTPException(404, "Bank connection not found")
    if conn.user_id and conn.user_id != user_id:
        raise HTTPException(403, "Forbidden")
    db.delete(conn)
    db.commit()
    return {"ok": True}


@app.put("/bank-connections/{conn_id}/link", response_model=BankConnectionOut)
def link_bank_to_account(conn_id: str, account_id: str = Query(...),
                         db: Session = Depends(get_db),
                         user_id: str = Depends(require_user_id)):
    """Link a TrueLayer bank connection to a LedgerVault account for syncing."""
    conn = db.query(models.BankConnection).filter_by(id=conn_id).first()
    if not conn:
        raise HTTPException(404, "Bank connection not found")
    if conn.user_id and conn.user_id != user_id:
        raise HTTPException(403, "Forbidden")
    conn.ledger_account_id = account_id
    db.commit()
    return _tl_conn_out(conn)


@app.post("/bank-connections/{conn_id}/sync", response_model=SyncResult)
def sync_bank_connection(conn_id: str, db: Session = Depends(get_db),
                          user_id: str = Depends(require_user_id)):
    """Import the last 90 days of transactions from TrueLayer."""
    conn = db.query(models.BankConnection).filter_by(id=conn_id).first()
    if not conn:
        raise HTTPException(404, "Bank connection not found")
    if conn.user_id and conn.user_id != user_id:
        raise HTTPException(403, "Forbidden")
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


# ─────────────────────────────────────────────────────────────────────────────
# Salt Edge Open Banking
# ─────────────────────────────────────────────────────────────────────────────

SALTEDGE_APP_ID    = os.getenv("SALTEDGE_APP_ID", "")
SALTEDGE_SECRET    = os.getenv("SALTEDGE_SECRET", "")
SALTEDGE_BASE_URL  = "https://www.saltedge.com/api/v6"
SALTEDGE_RETURN_URL = os.getenv(
    "SALTEDGE_RETURN_URL",
    "https://ledgervault-backend-production.up.railway.app/bank-connections-saltedge/callback"
)
SALTEDGE_DEEP_LINK = "ledgervault://saltedge/callback"


def _se_headers() -> dict:
    return {
        "App-id": SALTEDGE_APP_ID,
        "Secret": SALTEDGE_SECRET,
        "Content-Type": "application/json",
    }


def _se_conn_out(c: models.BankConnection) -> dict:
    return {
        "id": c.id,
        "provider": c.provider or "saltedge",
        "provider_id": c.provider_id,
        "provider_name": c.provider_name,
        "account_display_name": c.account_display_name,
        "account_type": c.account_type,
        "currency": c.currency,
        "saltedge_connection_id": c.saltedge_connection_id,
        "ledger_account_id": c.ledger_account_id,
        "last_synced": c.last_synced,
        "status": c.status,
    }


@app.get("/bank-connections-saltedge/auth-url")
def saltedge_auth_url(user_id: str = Depends(require_user_id)):
    """Create a Salt Edge connect session and return the connect_url for the iOS app."""
    if not SALTEDGE_APP_ID or not SALTEDGE_SECRET:
        raise HTTPException(500, "Salt Edge credentials not configured")

    headers = _se_headers()
    customer_identifier = f"ledgervault_{user_id}"

    # 1. Create customer (or handle already-existing)
    with httpx.Client(timeout=10) as c:
        r = c.post(f"{SALTEDGE_BASE_URL}/customers",
                   headers=headers,
                   json={"data": {"identifier": customer_identifier}})
        if r.status_code in (200, 201):
            customer_id = r.json()["data"]["id"]
        elif r.status_code == 409:
            # Already exists — fetch it
            r2 = c.get(f"{SALTEDGE_BASE_URL}/customers",
                       headers=headers,
                       params={"identifier": customer_identifier})
            if r2.status_code != 200:
                raise HTTPException(400, f"Salt Edge customer lookup failed: {r2.text[:200]}")
            items = r2.json().get("data", [])
            if not items:
                raise HTTPException(400, "Salt Edge customer not found after 409")
            customer_id = items[0]["id"]
        else:
            raise HTTPException(400, f"Salt Edge customer creation failed: {r.text[:200]}")

    # 2. Create connect session
    with httpx.Client(timeout=10) as c:
        r = c.post(f"{SALTEDGE_BASE_URL}/connect_sessions/create",
                   headers=headers,
                   json={"data": {
                       "customer_id": str(customer_id),
                       "consent": {
                           "scopes": ["account_details", "transactions_details"],
                           "from_date": "2020-01-01",
                       },
                       "attempt": {
                           "return_to": f"{SALTEDGE_RETURN_URL}?uid={user_id}",
                           "fetch_scopes": ["accounts", "transactions"],
                       },
                   }})
        if r.status_code not in (200, 201):
            raise HTTPException(400, f"Salt Edge connect session failed: {r.text[:200]}")
        connect_url = r.json()["data"]["connect_url"]

    return {"auth_url": connect_url, "state": str(customer_id)}


@app.get("/bank-connections-saltedge/callback")
def saltedge_callback(
    connection_id: str = Query(...),
    uid: Optional[str] = Query(None),   # user_id embedded in return_to URL
    db: Session = Depends(get_db),
):
    """Handle Salt Edge redirect after user connects a bank. Stores accounts then deep-links back to iOS."""
    from starlette.responses import RedirectResponse

    headers = _se_headers()

    # 1. Fetch connection details
    with httpx.Client(timeout=10) as c:
        r = c.get(f"{SALTEDGE_BASE_URL}/connections/{connection_id}", headers=headers)
        connection = r.json().get("data", {}) if r.status_code == 200 else {}

    provider_name = connection.get("provider_name", "Bank")
    provider_code = connection.get("provider_code", "unknown")

    # 2. Fetch accounts for this connection
    with httpx.Client(timeout=10) as c:
        r = c.get(f"{SALTEDGE_BASE_URL}/accounts",
                  headers=headers,
                  params={"connection_id": connection_id})
        if r.status_code != 200:
            return RedirectResponse(f"{SALTEDGE_DEEP_LINK}?error=fetch_failed")
        accounts = r.json().get("data", [])

    # 3. Persist each account as a BankConnection row
    created_count = 0
    for acct in accounts:
        se_acct_id   = str(acct["id"])
        unique_key   = f"se:{se_acct_id}"

        existing = db.query(models.BankConnection).filter_by(
            truelayer_account_id=unique_key
        ).first()

        if existing:
            existing.saltedge_connection_id = connection_id
            existing.status = "active"
            existing.status_message = None
        else:
            new_conn = models.BankConnection(
                id=str(uuid4()),
                user_id=uid,   # stamped from the return_to ?uid= param
                provider="saltedge",
                provider_id=provider_code,
                provider_name=provider_name,
                account_display_name=acct.get("name", "Account"),
                account_type=acct.get("nature", "account"),
                currency=acct.get("currency_code", "EUR"),
                truelayer_account_id=unique_key,
                saltedge_connection_id=connection_id,
                access_token="",   # Salt Edge uses App-id/Secret, not per-user tokens
                refresh_token="",
                status="active",
            )
            db.add(new_conn)
            created_count += 1

    db.commit()

    # 4. Redirect back to iOS app via deep link
    return RedirectResponse(f"{SALTEDGE_DEEP_LINK}?success=true&count={created_count}")


@app.get("/bank-connections-saltedge", response_model=BankConnectionList)
def list_saltedge_connections(db: Session = Depends(get_db),
                               user_id: str = Depends(require_user_id)):
    conns = (db.query(models.BankConnection)
               .filter(models.BankConnection.provider == "saltedge",
                       models.BankConnection.user_id == user_id).all())
    return {"items": [_se_conn_out(c) for c in conns]}


@app.post("/bank-connections-saltedge/{conn_id}/sync", response_model=SyncResult)
def sync_saltedge_connection(conn_id: str, db: Session = Depends(get_db),
                              user_id: str = Depends(require_user_id)):
    """Import the last 90 days of transactions from Salt Edge."""
    conn = db.query(models.BankConnection).filter_by(id=conn_id).first()
    if not conn:
        raise HTTPException(404, "Salt Edge connection not found")
    if conn.user_id and conn.user_id != user_id:
        raise HTTPException(403, "Forbidden")
    if not conn.ledger_account_id:
        raise HTTPException(400, "Link a LedgerVault account to this connection first.")
    if not conn.saltedge_connection_id:
        raise HTTPException(400, "Missing Salt Edge connection_id.")

    se_account_id = conn.truelayer_account_id.replace("se:", "")
    headers       = _se_headers()
    from_date     = (datetime.now(timezone.utc) - timedelta(days=90)).strftime("%Y-%m-%d")

    with httpx.Client(timeout=20) as c:
        r = c.get(f"{SALTEDGE_BASE_URL}/transactions",
                  headers=headers,
                  params={
                      "connection_id": conn.saltedge_connection_id,
                      "account_id":    se_account_id,
                      "from_date":     from_date,
                  })
        if r.status_code != 200:
            conn.status         = "error"
            conn.status_message = f"Salt Edge {r.status_code}: {r.text[:120]}"
            db.commit()
            raise HTTPException(400, conn.status_message)
        transactions = r.json().get("data", [])

    # Ensure fiat asset exists for this currency
    currency  = conn.currency or "EUR"
    fiat_asset = db.query(models.Asset).filter_by(symbol=currency).first()
    if not fiat_asset:
        fiat_asset = models.Asset(
            id=str(uuid4()), symbol=currency, name=currency,
            asset_class="fiat", quote_currency="USD"
        )
        db.add(fiat_asset)
        db.flush()

    imported = skipped = 0
    errors: list[str] = []

    for tx in transactions:
        tx_id       = str(tx.get("id", ""))
        external_id = f"saltedge:{conn.id}:{tx_id}"

        if db.query(models.TransactionEvent).filter_by(external_id=external_id).first():
            skipped += 1
            continue

        try:
            amount      = float(tx.get("amount", 0))
            event_type  = "income" if amount > 0 else "expense"
            description = (tx.get("description") or "")[:200]
            category    = tx.get("category", "other") or "other"
            tx_date     = tx.get("made_on", datetime.now(timezone.utc).strftime("%Y-%m-%d"))

            event = models.TransactionEvent(
                id=str(uuid4()), event_type=event_type,
                description=description, category=category,
                date=tx_date, source="saltedge", external_id=external_id,
            )
            db.add(event)
            db.flush()

            leg = models.TransactionLeg(
                id=str(uuid4()), event_id=event.id,
                account_id=conn.ledger_account_id,
                asset_id=fiat_asset.id,
                quantity=abs(amount) if amount > 0 else -abs(amount),
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


# ─────────────────────────────────────────────────────────────
# WALLET / RPC ADDRESS SCAN
# ─────────────────────────────────────────────────────────────

@app.get("/wallet-scan")
async def scan_wallet_address(
    address: str = Query(..., description="Public blockchain address"),
    chain:   str = Query("eth", description="Chain: eth | btc | sol | bnb | matic | arb | avax | trx"),
):
    """
    Scan any public blockchain address for its native-token balance.
    Uses free public APIs — no API key required.
    """
    chain   = chain.lower().strip()
    address = address.strip()

    # EVM-compatible chain config: rpc_url, symbol, decimals
    EVM = {
        "eth":  ("https://cloudflare-eth.com",                    "ETH",  18),
        "bnb":  ("https://bsc-dataseed.binance.org",              "BNB",  18),
        "matic":("https://polygon-rpc.com",                       "MATIC",18),
        "arb":  ("https://arb1.arbitrum.io/rpc",                  "ETH",  18),
        "avax": ("https://api.avax.network/ext/bc/C/rpc",         "AVAX", 18),
    }

    COINGECKO_IDS = {
        "eth": "ethereum", "btc": "bitcoin", "sol": "solana",
        "bnb": "binancecoin", "matic": "matic-network",
        "trx": "tron", "avax": "avalanche-2",
    }

    try:
        async with httpx.AsyncClient(timeout=15) as client:

            # ── EVM chains ──────────────────────────────────────────
            if chain in EVM:
                rpc_url, symbol, decimals = EVM[chain]
                r = await client.post(rpc_url, json={
                    "jsonrpc": "2.0", "method": "eth_getBalance",
                    "params":  [address, "latest"], "id": 1
                })
                r.raise_for_status()
                hex_bal = r.json().get("result", "0x0") or "0x0"
                balance = int(hex_bal, 16) / (10 ** decimals)

            # ── Bitcoin ─────────────────────────────────────────────
            elif chain == "btc":
                r = await client.get(f"https://mempool.space/api/address/{address}")
                r.raise_for_status()
                stats   = r.json().get("chain_stats", {})
                satoshi = stats.get("funded_txo_sum", 0) - stats.get("spent_txo_sum", 0)
                balance = satoshi / 1e8
                symbol  = "BTC"

            # ── Solana ──────────────────────────────────────────────
            elif chain == "sol":
                r = await client.post("https://api.mainnet-beta.solana.com", json={
                    "jsonrpc": "2.0", "id": 1,
                    "method":  "getBalance", "params": [address]
                })
                r.raise_for_status()
                lamports = r.json().get("result", {}).get("value", 0)
                balance  = lamports / 1e9
                symbol   = "SOL"

            # ── Tron ────────────────────────────────────────────────
            elif chain == "trx":
                r = await client.get(
                    f"https://api.trongrid.io/v1/accounts/{address}",
                    headers={"Accept": "application/json"},
                )
                r.raise_for_status()
                accounts = r.json().get("data", [])
                sun      = accounts[0].get("balance", 0) if accounts else 0
                balance  = sun / 1e6
                symbol   = "TRX"

            else:
                raise HTTPException(400, f"Unsupported chain '{chain}'. Use: eth, btc, sol, bnb, matic, arb, avax, trx")

            # ── Optional USD price lookup ────────────────────────────
            usd_value = None
            try:
                cg_id = COINGECKO_IDS.get(chain)
                if cg_id:
                    pr = await client.get(
                        f"https://api.coingecko.com/api/v3/simple/price?ids={cg_id}&vs_currencies=usd",
                        timeout=5,
                    )
                    usd_price = pr.json().get(cg_id, {}).get("usd", 0)
                    if usd_price:
                        usd_value = round(balance * usd_price, 2)
            except Exception:
                pass  # price is optional, don't fail the scan

            return {
                "address":   address,
                "chain":     chain,
                "balance":   round(balance, 8),
                "symbol":    symbol,
                "usd_value": usd_value,
            }

    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(500, f"Scan failed: {str(e)[:120]}")


# ─────────────────────────────────────────────────────────────────────────────
# Plaid Open Banking
# ─────────────────────────────────────────────────────────────────────────────

PLAID_CLIENT_ID  = os.getenv("PLAID_CLIENT_ID", "")
PLAID_SECRET     = os.getenv("PLAID_SECRET", "")
PLAID_ENV        = os.getenv("PLAID_ENV", "sandbox")   # sandbox | development | production
PLAID_BASE_URL   = f"https://{PLAID_ENV}.plaid.com"
PLAID_REDIRECT_URI = "ledgervault://plaid/callback"


def _plaid_headers() -> dict:
    return {
        "PLAID-CLIENT-ID": PLAID_CLIENT_ID,
        "PLAID-SECRET":    PLAID_SECRET,
        "Content-Type":    "application/json",
    }


@app.get("/bank-connections-plaid/auth-url")
def plaid_auth_url(user_id: str = Depends(require_user_id)):
    """Create a Plaid Link token and return the hosted link URL."""
    if not PLAID_CLIENT_ID or not PLAID_SECRET:
        raise HTTPException(500, "Plaid credentials not configured")

    with httpx.Client(timeout=10) as c:
        r = c.post(f"{PLAID_BASE_URL}/link/token/create",
                   headers=_plaid_headers(),
                   json={
                       "client_id":    PLAID_CLIENT_ID,
                       "secret":       PLAID_SECRET,
                       "client_name":  "LedgerVault",
                       "user":         {"client_user_id": f"ledgervault_{user_id}"},
                       "products":     ["transactions"],
                       "country_codes": ["US", "GB", "IE", "DE", "FR", "ES", "IT",
                                         "NL", "BE", "PT", "AT", "FI", "NO", "SE", "DK"],
                       "language":     "en",
                       "redirect_uri": PLAID_REDIRECT_URI,
                   })
        if r.status_code not in (200, 201):
            raise HTTPException(400, f"Plaid link token creation failed: {r.text[:300]}")

    link_token = r.json()["link_token"]
    auth_url   = f"https://cdn.plaid.com/link/v2/stable/link.html?token={link_token}"
    return {"auth_url": auth_url, "link_token": link_token}


@app.post("/bank-connections-plaid/exchange")
def plaid_exchange(
    public_token: str = Query(...),
    db: Session       = Depends(get_db),
    user_id: str      = Depends(require_user_id),
):
    """Exchange a Plaid public_token for an access_token, then fetch and store accounts."""
    if not PLAID_CLIENT_ID or not PLAID_SECRET:
        raise HTTPException(500, "Plaid credentials not configured")

    headers = _plaid_headers()

    # 1. Exchange public_token → access_token + item_id
    with httpx.Client(timeout=10) as c:
        r = c.post(f"{PLAID_BASE_URL}/item/public_token/exchange",
                   headers=headers,
                   json={"client_id": PLAID_CLIENT_ID, "secret": PLAID_SECRET,
                         "public_token": public_token})
        if r.status_code not in (200, 201):
            raise HTTPException(400, f"Plaid token exchange failed: {r.text[:300]}")
        data         = r.json()
        access_token = data["access_token"]
        item_id      = data["item_id"]

    # 2. Fetch accounts
    with httpx.Client(timeout=10) as c:
        r = c.post(f"{PLAID_BASE_URL}/accounts/get",
                   headers=headers,
                   json={"client_id": PLAID_CLIENT_ID, "secret": PLAID_SECRET,
                         "access_token": access_token})
        if r.status_code not in (200, 201):
            raise HTTPException(400, f"Plaid accounts fetch failed: {r.text[:300]}")
        accounts     = r.json().get("accounts", [])
        institution  = r.json().get("item", {})

    # 3. Fetch institution name
    inst_id   = institution.get("institution_id", "")
    inst_name = "Unknown Bank"
    if inst_id:
        with httpx.Client(timeout=10) as c:
            ri = c.post(f"{PLAID_BASE_URL}/institutions/get_by_id",
                        headers=headers,
                        json={"client_id": PLAID_CLIENT_ID, "secret": PLAID_SECRET,
                              "institution_id": inst_id, "country_codes": ["US","GB","IE","DE","FR","ES","IT","NL"]})
            if ri.status_code == 200:
                inst_name = ri.json().get("institution", {}).get("name", inst_name)

    encrypted_token = _encrypt(access_token)
    created = []

    # 4. Upsert a BankConnection row per account
    for acct in accounts:
        acct_id      = acct["account_id"]
        unique_key   = f"plaid:{item_id}:{acct_id}"
        display_name = acct.get("official_name") or acct.get("name") or "Account"
        acct_type    = acct.get("subtype") or acct.get("type") or "depository"
        currency     = (acct.get("balances") or {}).get("iso_currency_code") or "USD"

        existing = db.query(models.BankConnection).filter_by(
            truelayer_account_id=unique_key).first()
        if existing:
            existing.access_token = encrypted_token
            existing.status       = "active"
        else:
            existing = models.BankConnection(
                id=str(uuid.uuid4()),
                user_id=user_id,
                provider="plaid",
                provider_id=inst_id or item_id,
                provider_name=inst_name,
                account_display_name=display_name,
                account_type=acct_type,
                currency=currency,
                truelayer_account_id=unique_key,
                saltedge_connection_id=item_id,
                access_token=encrypted_token,
                refresh_token=None,
                status="active",
            )
            db.add(existing)
        created.append(existing.id)

    db.commit()
    return {"status": "ok", "connected": len(created), "institution": inst_name}


@app.get("/bank-connections-plaid")
def list_plaid_connections(db: Session = Depends(get_db),
                            user_id: str = Depends(require_user_id)):
    conns = (db.query(models.BankConnection)
               .filter(models.BankConnection.provider == "plaid",
                       models.BankConnection.user_id == user_id).all())
    return {"data": [_se_conn_out(c) for c in conns]}


@app.post("/bank-connections-plaid/{conn_id}/sync")
def sync_plaid_connection(conn_id: str, db: Session = Depends(get_db),
                           user_id: str = Depends(require_user_id)):
    """Import recent transactions for a Plaid connection."""
    conn = db.query(models.BankConnection).filter_by(id=conn_id).first()
    if not conn or conn.provider != "plaid":
        raise HTTPException(404, "Plaid connection not found")
    if conn.user_id and conn.user_id != user_id:
        raise HTTPException(403, "Forbidden")

    access_token = _decrypt(conn.access_token)
    if not access_token:
        raise HTTPException(400, "Missing Plaid access token")

    headers = _plaid_headers()
    from datetime import timedelta
    start = (datetime.now(timezone.utc) - timedelta(days=90)).strftime("%Y-%m-%d")
    end   = datetime.now(timezone.utc).strftime("%Y-%m-%d")

    with httpx.Client(timeout=15) as c:
        r = c.post(f"{PLAID_BASE_URL}/transactions/get",
                   headers=headers,
                   json={
                       "client_id":    PLAID_CLIENT_ID,
                       "secret":       PLAID_SECRET,
                       "access_token": access_token,
                       "start_date":   start,
                       "end_date":     end,
                       "options":      {"count": 500, "offset": 0},
                   })
        if r.status_code not in (200, 201):
            raise HTTPException(400, f"Plaid transactions fetch failed: {r.text[:300]}")
        transactions = r.json().get("transactions", [])

    # Extract the Plaid account_id from the unique key (plaid:{item_id}:{acct_id})
    plaid_account_id = conn.truelayer_account_id.split(":")[-1] if conn.truelayer_account_id else None

    # Find or create a ledger account
    ledger_acct = None
    if conn.ledger_account_id:
        ledger_acct = db.query(models.Account).filter_by(id=conn.ledger_account_id).first()
    if not ledger_acct:
        ledger_acct = models.Account(
            id=str(uuid.uuid4()),
            name=f"{conn.provider_name} — {conn.account_display_name}",
            account_type="bank",
            base_currency=conn.currency or "USD",
        )
        db.add(ledger_acct)
        conn.ledger_account_id = ledger_acct.id
        db.flush()

    # Get or create fiat asset
    currency = conn.currency or "USD"
    asset = db.query(models.Asset).filter(
        models.Asset.symbol == currency
    ).first()
    if not asset:
        asset = models.Asset(
            id=str(uuid.uuid4()),
            symbol=currency,
            name=currency,
            asset_class="fiat",
            quote_currency="USD",
        )
        db.add(asset)
        db.flush()

    imported = 0
    for tx in transactions:
        if plaid_account_id and tx.get("account_id") != plaid_account_id:
            continue
        ext_id = f"plaid:{conn.id}:{tx['transaction_id']}"
        if db.query(models.TransactionEvent).filter_by(external_id=ext_id).first():
            continue

        amount   = tx.get("amount", 0)   # Plaid: positive = debit (money out)
        tx_date  = tx.get("date", end)
        name     = tx.get("name") or tx.get("merchant_name") or "Transaction"
        cat_list = tx.get("category") or []
        category = cat_list[-1] if cat_list else "expense"

        event = models.TransactionEvent(
            id=str(uuid.uuid4()),
            event_type="expense" if amount > 0 else "income",
            category=category.lower(),
            description=name,
            date=tx_date,
            source="plaid",
            external_id=ext_id,
        )
        db.add(event)
        db.flush()

        leg = models.TransactionLeg(
            id=str(uuid.uuid4()),
            event_id=event.id,
            account_id=ledger_acct.id,
            asset_id=asset.id,
            quantity=round(-amount, 8),   # negate: plaid positive = outflow for us
            unit_price=1.0,
            fee_flag="false",
        )
        db.add(leg)
        imported += 1

    conn.last_synced = datetime.now(timezone.utc).isoformat()
    conn.status      = "active"
    db.commit()
    return {"status": "ok", "imported": imported}


# ─────────────────────────────────────────────────────────────────────────────
# SNAPTRADE — Broker Aggregator (Fidelity, Webull, Vanguard, Robinhood, IBKR…)
# Activate by setting SNAPTRADE_CLIENT_ID + SNAPTRADE_CONSUMER_KEY on Railway.
# ─────────────────────────────────────────────────────────────────────────────
SNAPTRADE_CLIENT_ID    = os.getenv("SNAPTRADE_CLIENT_ID", "")
SNAPTRADE_CONSUMER_KEY = os.getenv("SNAPTRADE_CONSUMER_KEY", "")
SNAPTRADE_BASE         = "https://api.snaptrade.com/api/v1"

def _snaptrade_configured() -> bool:
    return bool(SNAPTRADE_CLIENT_ID and SNAPTRADE_CONSUMER_KEY)

def _snaptrade_sig(path: str, query: str = "", body: str = "") -> dict:
    """Build SnapTrade HMAC-SHA256 request signature headers."""
    ts = str(int(time.time()))
    msg = ts + path + query + body
    sig = base64.b64encode(
        hmac.new(SNAPTRADE_CONSUMER_KEY.encode(), msg.encode(), hashlib.sha256).digest()
    ).decode()
    return {
        "Signature": sig,
        "timestamp": ts,
        "clientId": SNAPTRADE_CLIENT_ID,
        "Content-Type": "application/json",
    }


@app.post("/snaptrade/register")
@limiter.limit("5/minute")
def snaptrade_register(request: Request, user_id: str = Depends(require_user_id),
                       db: Session = Depends(get_db)):
    """Register user with SnapTrade (idempotent). Returns userSecret."""
    if not _snaptrade_configured():
        raise HTTPException(503, "SnapTrade not configured — add SNAPTRADE_CLIENT_ID and SNAPTRADE_CONSUMER_KEY")
    existing = db.query(models.SnaptradeConnection).filter_by(user_id=user_id).first()
    if existing:
        return {"snaptrade_user_id": existing.snaptrade_user_id}

    path = "/snapTrade/registerUser"
    body = json.dumps({"userId": user_id})
    headers = _snaptrade_sig(path, body=body)
    with httpx.Client(timeout=15.0) as c:
        r = c.post(f"{SNAPTRADE_BASE}{path}?clientId={SNAPTRADE_CLIENT_ID}", json={"userId": user_id}, headers=headers)
        if r.status_code not in (200, 201):
            raise HTTPException(500, f"SnapTrade register failed: {r.text}")
        data = r.json()

    conn = models.SnaptradeConnection(
        id=str(uuid4()), user_id=user_id,
        snaptrade_user_id=data.get("userId", user_id),
        snaptrade_secret=_encrypt(data.get("userSecret", "")),
    )
    db.add(conn); db.commit()
    return {"snaptrade_user_id": conn.snaptrade_user_id}


@app.get("/snaptrade/auth-url")
@limiter.limit("10/minute")
def snaptrade_auth_url(request: Request, broker: str = Query(""), user_id: str = Depends(require_user_id),
                       db: Session = Depends(get_db)):
    """Get SnapTrade OAuth redirect URL for a specific broker."""
    if not _snaptrade_configured():
        raise HTTPException(503, "SnapTrade not configured")
    conn = db.query(models.SnaptradeConnection).filter_by(user_id=user_id).first()
    if not conn:
        raise HTTPException(400, "Register with SnapTrade first via POST /snaptrade/register")
    secret = _decrypt(conn.snaptrade_secret)

    path = "/snapTrade/login"
    params = f"clientId={SNAPTRADE_CLIENT_ID}&userSecret={secret}&userId={conn.snaptrade_user_id}"
    if broker:
        params += f"&broker={broker}"
    headers = _snaptrade_sig(path, query=params)
    with httpx.Client(timeout=15.0) as c:
        r = c.get(f"{SNAPTRADE_BASE}{path}?{params}", headers=headers)
        r.raise_for_status()
        data = r.json()
    return {"auth_url": data.get("redirectURI", "")}


@app.get("/snaptrade/connections")
def snaptrade_connections(user_id: str = Depends(require_user_id), db: Session = Depends(get_db)):
    """List SnapTrade broker connections for the user."""
    if not _snaptrade_configured():
        return {"items": [], "configured": False}
    conns = db.query(models.SnaptradeConnection).filter_by(user_id=user_id).all()
    return {"items": [{"id": c.id, "brokerage_name": c.brokerage_name,
                       "brokerage_id": c.brokerage_id, "status": c.status,
                       "last_synced": c.last_synced} for c in conns],
            "configured": True}


@app.post("/snaptrade/{conn_id}/sync", response_model=SyncResult)
def snaptrade_sync(conn_id: str, user_id: str = Depends(require_user_id), db: Session = Depends(get_db)):
    """Import holdings from a SnapTrade broker connection."""
    if not _snaptrade_configured():
        raise HTTPException(503, "SnapTrade not configured")
    st_conn = db.query(models.SnaptradeConnection).filter_by(id=conn_id, user_id=user_id).first()
    if not st_conn:
        raise HTTPException(404, "SnapTrade connection not found")
    secret = _decrypt(st_conn.snaptrade_secret)
    target_account = db.query(models.Account).filter_by(id=st_conn.account_id).first() if st_conn.account_id else None
    if not target_account:
        return SyncResult(imported=0, skipped=0, errors=["No linked account — link this connection to an account first"], status="error")

    imported = skipped = 0; errors = []
    path = "/holdings"
    params = f"clientId={SNAPTRADE_CLIENT_ID}&userSecret={secret}&userId={st_conn.snaptrade_user_id}"
    headers = _snaptrade_sig(path, query=params)
    try:
        with httpx.Client(timeout=20.0) as c:
            r = c.get(f"{SNAPTRADE_BASE}{path}?{params}", headers=headers)
            r.raise_for_status()
            accounts_data = r.json()
    except Exception as e:
        return SyncResult(imported=0, skipped=0, errors=[f"SnapTrade fetch failed: {e}"], status="error")

    for acct in (accounts_data if isinstance(accounts_data, list) else []):
        for pos in acct.get("positions", []):
            sym = (pos.get("symbol", {}).get("symbol") or pos.get("ticker", "")).upper()
            qty = float(pos.get("units", 0))
            avg_price = float(pos.get("average_purchase_price", 0))
            if not sym or qty <= 0: continue
            try:
                asset = db.query(models.Asset).filter_by(symbol=sym).first()
                if not asset:
                    asset = models.Asset(id=str(uuid4()), symbol=sym, name=sym, asset_class="stock", quote_currency="USD")
                    db.add(asset); db.flush()
                holding = db.query(models.Holding).filter_by(account_id=target_account.id, asset_id=asset.id).first()
                if not holding:
                    holding = models.Holding(id=str(uuid4()), account_id=target_account.id,
                                            asset_id=asset.id, quantity=qty, avg_cost=avg_price)
                    db.add(holding)
                else:
                    holding.quantity = qty; holding.avg_cost = avg_price
                db.commit(); imported += 1
            except Exception as e:
                db.rollback(); errors.append(f"{sym}: {e}")

    st_conn.last_synced = _utc_now_iso(); st_conn.status = "active" if not errors else "error"
    db.commit()
    return SyncResult(imported=imported, skipped=skipped, errors=errors[:10], status=st_conn.status)


@app.delete("/snaptrade/{conn_id}")
def snaptrade_delete(conn_id: str, user_id: str = Depends(require_user_id), db: Session = Depends(get_db)):
    conn = db.query(models.SnaptradeConnection).filter_by(id=conn_id, user_id=user_id).first()
    if not conn: raise HTTPException(404, "Not found")
    db.delete(conn); db.commit()
    return {"status": "ok"}


# ─────────────────────────────────────────────────────────────────────────────
# VEZGO — Crypto Exchange Aggregator (Bitpanda, Nexo, Binance US, Bittrex…)
# Activate by setting VEZGO_CLIENT_ID + VEZGO_CLIENT_SECRET on Railway.
# ─────────────────────────────────────────────────────────────────────────────
VEZGO_CLIENT_ID     = os.getenv("VEZGO_CLIENT_ID", "")
VEZGO_CLIENT_SECRET = os.getenv("VEZGO_CLIENT_SECRET", "")
VEZGO_BASE          = "https://api.vezgo.com/v1"


def _vezgo_configured() -> bool:
    return bool(VEZGO_CLIENT_ID and VEZGO_CLIENT_SECRET)


@app.get("/vezgo/auth-url")
@limiter.limit("10/minute")
def vezgo_auth_url(request: Request, user_id: str = Depends(require_user_id)):
    """Get Vezgo OAuth redirect URL."""
    if not _vezgo_configured():
        raise HTTPException(503, "Vezgo not configured — add VEZGO_CLIENT_ID and VEZGO_CLIENT_SECRET")
    redirect = "ledgervault://vezgo/callback"
    url = (f"https://connect.vezgo.com/connect?client_id={VEZGO_CLIENT_ID}"
           f"&redirect_uri={urllib.parse.quote(redirect)}&response_type=code&state={user_id}")
    return {"auth_url": url}


@app.post("/vezgo/callback")
@limiter.limit("10/minute")
def vezgo_callback(request: Request, code: str = Query(...), state: str = Query(""),
                   user_id: str = Depends(require_user_id), db: Session = Depends(get_db)):
    """Exchange Vezgo authorization code for tokens and save connection."""
    if not _vezgo_configured():
        raise HTTPException(503, "Vezgo not configured")
    with httpx.Client(timeout=15.0) as c:
        r = c.post(f"{VEZGO_BASE}/auth/token", json={
            "grant_type": "authorization_code", "code": code,
            "client_id": VEZGO_CLIENT_ID, "client_secret": VEZGO_CLIENT_SECRET,
            "redirect_uri": "ledgervault://vezgo/callback",
        })
        r.raise_for_status()
        tokens = r.json()
    conn = models.VezgoConnection(
        id=str(uuid4()), user_id=user_id,
        vezgo_user_id=tokens.get("user_id", user_id),
        vezgo_token=_encrypt(tokens.get("access_token", "")),
    )
    db.add(conn); db.commit()
    return {"status": "ok", "id": conn.id}


@app.get("/vezgo/connections")
def vezgo_connections(user_id: str = Depends(require_user_id), db: Session = Depends(get_db)):
    if not _vezgo_configured():
        return {"items": [], "configured": False}
    conns = db.query(models.VezgoConnection).filter_by(user_id=user_id).all()
    return {"items": [{"id": c.id, "account_name": c.account_name, "status": c.status,
                        "last_synced": c.last_synced} for c in conns], "configured": True}


@app.post("/vezgo/{conn_id}/sync", response_model=SyncResult)
def vezgo_sync(conn_id: str, user_id: str = Depends(require_user_id), db: Session = Depends(get_db)):
    if not _vezgo_configured():
        raise HTTPException(503, "Vezgo not configured")
    vconn = db.query(models.VezgoConnection).filter_by(id=conn_id, user_id=user_id).first()
    if not vconn: raise HTTPException(404, "Not found")
    token = _decrypt(vconn.vezgo_token or "")
    target_account = db.query(models.Account).filter_by(id=vconn.account_id).first() if vconn.account_id else None
    if not target_account:
        return SyncResult(imported=0, skipped=0, errors=["No linked account"], status="error")

    imported = skipped = 0; errors = []
    try:
        with httpx.Client(timeout=20.0) as c:
            r = c.get(f"{VEZGO_BASE}/accounts/{vconn.vezgo_user_id}/balances",
                      headers={"Authorization": f"Bearer {token}"})
            r.raise_for_status(); balances = r.json()
    except Exception as e:
        return SyncResult(imported=0, skipped=0, errors=[f"Vezgo fetch failed: {e}"], status="error")

    for bal in (balances if isinstance(balances, list) else []):
        sym = (bal.get("ticker") or bal.get("currency", "")).upper()
        qty = float(bal.get("amount", 0))
        fiat_val = float(bal.get("fiat_value", 0))
        price = fiat_val / qty if qty > 0 else 0
        if not sym or qty <= 0: continue
        try:
            asset = db.query(models.Asset).filter_by(symbol=sym).first()
            if not asset:
                asset = models.Asset(id=str(uuid4()), symbol=sym, name=sym, asset_class="crypto", quote_currency="USD")
                db.add(asset); db.flush()
            holding = db.query(models.Holding).filter_by(account_id=target_account.id, asset_id=asset.id).first()
            if not holding:
                holding = models.Holding(id=str(uuid4()), account_id=target_account.id,
                                        asset_id=asset.id, quantity=qty, avg_cost=price)
                db.add(holding)
            else:
                holding.quantity = qty; holding.avg_cost = price
            db.commit(); imported += 1
        except Exception as e:
            db.rollback(); errors.append(f"{sym}: {e}")

    vconn.last_synced = _utc_now_iso(); vconn.status = "active" if not errors else "error"
    db.commit()
    return SyncResult(imported=imported, skipped=skipped, errors=errors[:10], status=vconn.status)


@app.delete("/vezgo/{conn_id}")
def vezgo_delete(conn_id: str, user_id: str = Depends(require_user_id), db: Session = Depends(get_db)):
    conn = db.query(models.VezgoConnection).filter_by(id=conn_id, user_id=user_id).first()
    if not conn: raise HTTPException(404, "Not found")
    db.delete(conn); db.commit()
    return {"status": "ok"}


# ─────────────────────────────────────────────────────────────────────────────
# FLANKS — European Broker Aggregator (Trade Republic, XTB, Freetrade, Saxo…)
# Activate by setting FLANKS_API_KEY on Railway.
# ─────────────────────────────────────────────────────────────────────────────
FLANKS_API_KEY  = os.getenv("FLANKS_API_KEY", "")
FLANKS_BASE     = "https://api.flanks.io/v1"


def _flanks_configured() -> bool:
    return bool(FLANKS_API_KEY)


def _flanks_headers() -> dict:
    return {"Authorization": f"Bearer {FLANKS_API_KEY}", "Content-Type": "application/json"}


@app.get("/flanks/brokers")
def flanks_brokers():
    """Return list of supported Flanks brokers."""
    if not _flanks_configured():
        return {"items": [], "configured": False}
    try:
        with httpx.Client(timeout=15.0) as c:
            r = c.get(f"{FLANKS_BASE}/brokers", headers=_flanks_headers())
            r.raise_for_status()
            return {"items": r.json(), "configured": True}
    except Exception as e:
        return {"items": [], "configured": True, "error": str(e)}


@app.post("/flanks/connect")
@limiter.limit("5/minute")
def flanks_connect(request: Request, payload: dict, user_id: str = Depends(require_user_id),
                   db: Session = Depends(get_db)):
    """Initiate Flanks broker connection (returns redirect URL)."""
    if not _flanks_configured():
        raise HTTPException(503, "Flanks not configured — add FLANKS_API_KEY")
    broker_id = payload.get("broker_id", "")
    if not broker_id:
        raise HTTPException(400, "broker_id required")
    try:
        with httpx.Client(timeout=15.0) as c:
            r = c.post(f"{FLANKS_BASE}/connections", headers=_flanks_headers(),
                       json={"brokerId": broker_id, "userId": user_id,
                             "redirectUri": "ledgervault://flanks/callback"})
            r.raise_for_status()
            data = r.json()
    except Exception as e:
        raise HTTPException(500, f"Flanks connect failed: {e}")

    conn = models.FlanksBrokerConnection(
        id=str(uuid4()), user_id=user_id,
        broker_id=broker_id, broker_name=data.get("brokerName"),
        flanks_user_id=data.get("connectionId"),
    )
    db.add(conn); db.commit()
    return {"auth_url": data.get("authorizationUrl", ""), "id": conn.id}


@app.get("/flanks/connections")
def flanks_connections(user_id: str = Depends(require_user_id), db: Session = Depends(get_db)):
    if not _flanks_configured():
        return {"items": [], "configured": False}
    conns = db.query(models.FlanksBrokerConnection).filter_by(user_id=user_id).all()
    return {"items": [{"id": c.id, "broker_id": c.broker_id, "broker_name": c.broker_name,
                        "status": c.status, "last_synced": c.last_synced} for c in conns],
            "configured": True}


@app.post("/flanks/{conn_id}/sync", response_model=SyncResult)
def flanks_sync(conn_id: str, user_id: str = Depends(require_user_id), db: Session = Depends(get_db)):
    if not _flanks_configured():
        raise HTTPException(503, "Flanks not configured")
    fconn = db.query(models.FlanksBrokerConnection).filter_by(id=conn_id, user_id=user_id).first()
    if not fconn: raise HTTPException(404, "Not found")
    target_account = db.query(models.Account).filter_by(id=fconn.account_id).first() if fconn.account_id else None
    if not target_account:
        return SyncResult(imported=0, skipped=0, errors=["No linked account"], status="error")

    imported = skipped = 0; errors = []
    try:
        with httpx.Client(timeout=20.0) as c:
            r = c.get(f"{FLANKS_BASE}/connections/{fconn.flanks_user_id}/positions",
                      headers=_flanks_headers())
            r.raise_for_status(); positions = r.json()
    except Exception as e:
        return SyncResult(imported=0, skipped=0, errors=[f"Flanks fetch failed: {e}"], status="error")

    for pos in (positions if isinstance(positions, list) else positions.get("items", [])):
        sym = (pos.get("ticker") or pos.get("symbol", "")).upper()
        qty = float(pos.get("quantity", 0))
        avg_price = float(pos.get("averagePrice", pos.get("avg_price", 0)))
        if not sym or qty <= 0: continue
        try:
            asset = db.query(models.Asset).filter_by(symbol=sym).first()
            if not asset:
                asset = models.Asset(id=str(uuid4()), symbol=sym, name=pos.get("name", sym),
                                    asset_class="stock", quote_currency="EUR")
                db.add(asset); db.flush()
            holding = db.query(models.Holding).filter_by(account_id=target_account.id, asset_id=asset.id).first()
            if not holding:
                holding = models.Holding(id=str(uuid4()), account_id=target_account.id,
                                        asset_id=asset.id, quantity=qty, avg_cost=avg_price)
                db.add(holding)
            else:
                holding.quantity = qty; holding.avg_cost = avg_price
            db.commit(); imported += 1
        except Exception as e:
            db.rollback(); errors.append(f"{sym}: {e}")

    fconn.last_synced = _utc_now_iso(); fconn.status = "active" if not errors else "error"
    db.commit()
    return SyncResult(imported=imported, skipped=skipped, errors=errors[:10], status=fconn.status)


@app.delete("/flanks/{conn_id}")
def flanks_delete(conn_id: str, user_id: str = Depends(require_user_id), db: Session = Depends(get_db)):
    conn = db.query(models.FlanksBrokerConnection).filter_by(id=conn_id, user_id=user_id).first()
    if not conn: raise HTTPException(404, "Not found")
    db.delete(conn); db.commit()
    return {"status": "ok"}


# ─────────────────────────────────────────────────────────────────────────────
# MARKETS  —  live quotes, sparklines, watchlist
# ─────────────────────────────────────────────────────────────────────────────

_QUOTE_CACHE: dict[str, dict] = {}   # symbol → {quote dict, ts}
_QUOTE_CACHE_TTL = 10  # seconds


def _fetch_single_quote(symbol: str) -> dict | None:
    """Fetch a single quote — delegates to batch fetcher."""
    results = _fetch_yahoo_quotes([symbol])
    return results.get(symbol.upper())


# ════════════════════════════════════════════════════════════════════════════
#  CRYPTO WALLET BALANCE FETCHERS (all free, no paid APIs)
# ════════════════════════════════════════════════════════════════════════════

def _evm_token_balances(address: str, api_base: str, api_key: str) -> list[dict]:
    """Discover ERC-20/BEP-20/Polygon tokens via transfer history, return non-zero balances."""
    h = {"User-Agent": "Mozilla/5.0"}
    key = f"&apikey={api_key}" if api_key else ""
    tokens: dict[str, dict] = {}
    try:
        url = (f"{api_base}?module=account&action=tokentx&address={address}"
               f"&sort=desc&page=1&offset=200{key}")
        with httpx.Client(timeout=12, headers=h) as c:
            r = c.get(url); r.raise_for_status()
        if r.json().get("status") == "1":
            for tx in r.json().get("result", []):
                ca = tx.get("contractAddress", "").lower()
                if ca and ca not in tokens:
                    tokens[ca] = {
                        "symbol":   tx.get("tokenSymbol", "???"),
                        "name":     tx.get("tokenName", ""),
                        "decimals": int(tx.get("tokenDecimal", 18) or 18),
                    }
    except Exception as e:
        logger.warning(f"EVM token discovery failed: {e}")
        return []

    balances = []
    for ca, info in list(tokens.items())[:40]:
        try:
            url2 = (f"{api_base}?module=account&action=tokenbalance"
                    f"&contractaddress={ca}&address={address}&tag=latest{key}")
            with httpx.Client(timeout=8, headers=h) as c:
                r = c.get(url2); r.raise_for_status()
            d = r.json()
            if d.get("status") == "1":
                raw = int(d.get("result", 0) or 0)
                bal = raw / (10 ** info["decimals"])
                if bal > 1e-8:
                    balances.append({"symbol": info["symbol"], "name": info["name"],
                                     "balance": bal, "contract": ca})
        except Exception:
            pass
    return balances


def _fetch_btc_balance(address: str) -> tuple[float, list]:
    try:
        with httpx.Client(timeout=10, headers={"User-Agent": "Mozilla/5.0"}) as c:
            r = c.get(f"https://blockstream.info/api/address/{address}"); r.raise_for_status()
        d = r.json()
        cs = d.get("chain_stats", {}); ms = d.get("mempool_stats", {})
        funded = cs.get("funded_txo_sum", 0) + ms.get("funded_txo_sum", 0)
        spent  = cs.get("spent_txo_sum",  0) + ms.get("spent_txo_sum",  0)
        return (funded - spent) / 1e8, []
    except Exception as e:
        logger.warning(f"BTC balance failed {address}: {e}"); return 0.0, []


def _fetch_eth_balance(address: str) -> tuple[float, list]:
    key = f"&apikey={ETHERSCAN_KEY}" if ETHERSCAN_KEY else ""
    native = 0.0
    try:
        url = f"https://api.etherscan.io/api?module=account&action=balance&address={address}&tag=latest{key}"
        with httpx.Client(timeout=10, headers={"User-Agent": "Mozilla/5.0"}) as c:
            r = c.get(url); r.raise_for_status()
        d = r.json()
        if d.get("status") == "1": native = int(d["result"]) / 1e18
    except Exception as e:
        logger.warning(f"ETH balance failed: {e}")
    tokens = _evm_token_balances(address, "https://api.etherscan.io/api", ETHERSCAN_KEY)
    return native, tokens


def _fetch_bnb_balance(address: str) -> tuple[float, list]:
    key = f"&apikey={BSCSCAN_KEY}" if BSCSCAN_KEY else ""
    native = 0.0
    try:
        url = f"https://api.bscscan.com/api?module=account&action=balance&address={address}&tag=latest{key}"
        with httpx.Client(timeout=10, headers={"User-Agent": "Mozilla/5.0"}) as c:
            r = c.get(url); r.raise_for_status()
        d = r.json()
        if d.get("status") == "1": native = int(d["result"]) / 1e18
    except Exception as e:
        logger.warning(f"BNB balance failed: {e}")
    tokens = _evm_token_balances(address, "https://api.bscscan.com/api", BSCSCAN_KEY)
    return native, tokens


def _fetch_matic_balance(address: str) -> tuple[float, list]:
    key = f"&apikey={POLYGONSCAN_KEY}" if POLYGONSCAN_KEY else ""
    native = 0.0
    try:
        url = f"https://api.polygonscan.com/api?module=account&action=balance&address={address}&tag=latest{key}"
        with httpx.Client(timeout=10, headers={"User-Agent": "Mozilla/5.0"}) as c:
            r = c.get(url); r.raise_for_status()
        d = r.json()
        if d.get("status") == "1": native = int(d["result"]) / 1e18
    except Exception as e:
        logger.warning(f"MATIC balance failed: {e}")
    tokens = _evm_token_balances(address, "https://api.polygonscan.com/api", POLYGONSCAN_KEY)
    return native, tokens


def _fetch_trx_balance(address: str) -> tuple[float, list]:
    try:
        with httpx.Client(timeout=12, headers={"User-Agent": "Mozilla/5.0"}) as c:
            r = c.get(f"https://apilist.tronscanapi.com/api/account?address={address}"); r.raise_for_status()
        d = r.json()
        native = d.get("balance", 0) / 1e6
        tokens = []
        for tok in d.get("trc20token_balances", []):
            dec = int(tok.get("tokenDecimal", 6) or 6)
            bal = float(tok.get("balance", 0) or 0) / (10 ** dec)
            if bal > 1e-8:
                tokens.append({"symbol": tok.get("tokenAbbr", "").upper(),
                                "name": tok.get("tokenName", ""),
                                "balance": bal, "contract": tok.get("tokenId", "")})
        return native, tokens
    except Exception as e:
        logger.warning(f"TRX balance failed {address}: {e}"); return 0.0, []


def _fetch_sol_balance(address: str) -> tuple[float, list]:
    rpc = "https://api.mainnet-beta.solana.com"
    h   = {"Content-Type": "application/json", "User-Agent": "Mozilla/5.0"}
    native = 0.0
    tokens = []
    try:
        with httpx.Client(timeout=10, headers=h) as c:
            r = c.post(rpc, json={"jsonrpc": "2.0", "id": 1, "method": "getBalance",
                                   "params": [address]}); r.raise_for_status()
        native = r.json().get("result", {}).get("value", 0) / 1e9
    except Exception as e:
        logger.warning(f"SOL balance failed: {e}")
    try:
        payload = {"jsonrpc": "2.0", "id": 2, "method": "getTokenAccountsByOwner",
                   "params": [address,
                               {"programId": "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"},
                               {"encoding": "jsonParsed"}]}
        with httpx.Client(timeout=10, headers=h) as c:
            r = c.post(rpc, json=payload); r.raise_for_status()
        for acct in r.json().get("result", {}).get("value", []):
            info = acct.get("account", {}).get("data", {}).get("parsed", {}).get("info", {})
            ta   = info.get("tokenAmount", {})
            bal  = float(ta.get("uiAmount", 0) or 0)
            if bal > 1e-8:
                mint = info.get("mint", "")
                tokens.append({"symbol": mint[:8], "name": mint,
                                "balance": bal, "contract": mint})
    except Exception as e:
        logger.warning(f"SOL tokens failed: {e}")
    return native, tokens


def _fetch_xrp_balance(address: str) -> tuple[float, list]:
    try:
        payload = {"method": "account_info",
                   "params": [{"account": address, "ledger_index": "current"}]}
        with httpx.Client(timeout=10, headers={"Content-Type": "application/json"}) as c:
            r = c.post("https://xrplcluster.com/", json=payload); r.raise_for_status()
        result = r.json().get("result", {})
        if result.get("status") == "success":
            drops = int(result.get("account_data", {}).get("Balance", 0))
            return drops / 1e6, []
        return 0.0, []
    except Exception as e:
        logger.warning(f"XRP balance failed {address}: {e}"); return 0.0, []


def _fetch_ltc_balance(address: str) -> tuple[float, list]:
    try:
        url = f"https://api.blockchair.com/litecoin/addresses/balances?addresses={address}"
        with httpx.Client(timeout=10, headers={"User-Agent": "Mozilla/5.0"}) as c:
            r = c.get(url); r.raise_for_status()
        sats = r.json().get("data", {}).get(address.lower(), 0)
        return sats / 1e8, []
    except Exception as e:
        logger.warning(f"LTC balance failed {address}: {e}"); return 0.0, []


_CHAIN_FETCHERS = {
    "BTC":   _fetch_btc_balance,
    "ETH":   _fetch_eth_balance,
    "BNB":   _fetch_bnb_balance,
    "MATIC": _fetch_matic_balance,
    "POL":   _fetch_matic_balance,   # same chain, rebranded
    "TRX":   _fetch_trx_balance,
    "SOL":   _fetch_sol_balance,
    "XRP":   _fetch_xrp_balance,
    "LTC":   _fetch_ltc_balance,
}

SUPPORTED_CHAINS = list(_CHAIN_FETCHERS.keys())


def _wallet_to_holdings(chain: str, address: str) -> list[dict]:
    """
    Fetch wallet balances and return a list of {symbol, name, balance, value_usd}.
    Uses live CoinGecko / Yahoo prices for valuation.
    """
    fetcher = _CHAIN_FETCHERS.get(chain.upper())
    if not fetcher:
        return []
    native_bal, tokens = fetcher(address)

    # Build symbol list for price lookup
    native_sym = chain.upper()
    syms_needed = [native_sym] + [t["symbol"].upper() for t in tokens]

    # Get prices (reuse existing crypto price cache)
    prices = {}
    try:
        fx = _get_fx_rates()
        crypto_prices = _get_crypto_prices()
        for sym in syms_needed:
            if sym in crypto_prices:
                prices[sym] = crypto_prices[sym]
    except Exception:
        pass

    results = []
    if native_bal > 1e-8:
        price = prices.get(native_sym, 0)
        results.append({
            "symbol":    native_sym,
            "name":      chain.upper(),
            "balance":   native_bal,
            "price_usd": price,
            "value_usd": native_bal * price,
            "is_native": True,
        })
    for tok in tokens:
        sym = tok["symbol"].upper()
        price = prices.get(sym, 0)
        results.append({
            "symbol":    sym,
            "name":      tok["name"],
            "balance":   tok["balance"],
            "price_usd": price,
            "value_usd": tok["balance"] * price,
            "is_native": False,
            "contract":  tok.get("contract", ""),
        })
    return results


def _calc_market_state(exchange: str, tz_name: str = "") -> str | None:
    """
    Derive market state from IANA timezone name (preferred) or exchange name string.
    Returns None only if the exchange is truly unrecognised — caller keeps Yahoo's value.
    """
    now   = datetime.now(timezone.utc)
    wd    = now.weekday()   # 0=Mon … 6=Sun
    t_utc = now.hour * 60 + now.minute
    mo    = now.month

    def lt(off: int) -> int:            # local minutes since midnight
        return (t_utc + off * 60) % 1440

    tz   = (tz_name  or "").upper()
    exch = (exchange or "").upper()

    # ── Primary: IANA timezone (returned by Yahoo v7 as exchangeTimezoneName) ─
    # America/New_York → ET
    if any(x in tz for x in ["AMERICA/NEW_YORK","AMERICA/CHICAGO","AMERICA/DETROIT",
                              "AMERICA/INDIANA","AMERICA/KENTUCKY"]):
        if wd >= 5: return "CLOSED"
        off = -4 if 3 <= mo <= 11 else -5
        ltt = lt(off)
        if   4*60    <= ltt < 9*60+30:  return "PRE"
        elif 9*60+30 <= ltt < 16*60:    return "REGULAR"
        elif 16*60   <= ltt < 20*60:    return "POST"
        return "CLOSED"

    # Asia/Dubai → UTC+4, no DST
    if any(x in tz for x in ["ASIA/DUBAI","ASIA/MUSCAT"]):
        if wd >= 5: return "CLOSED"
        ltt = lt(4)
        if 10*60 <= ltt < 14*60+30: return "REGULAR"
        return "CLOSED"

    # Europe/Paris / Amsterdam / Euronext zone → CET/CEST
    if any(x in tz for x in ["EUROPE/PARIS","EUROPE/AMSTERDAM","EUROPE/BRUSSELS",
                              "EUROPE/LISBON","EUROPE/MADRID","EUROPE/ROME",
                              "EUROPE/OSLO","EUROPE/STOCKHOLM","EUROPE/COPENHAGEN",
                              "EUROPE/WARSAW","EUROPE/PRAGUE","EUROPE/BUDAPEST"]):
        if wd >= 5: return "CLOSED"
        off = 2 if 3 <= mo <= 10 else 1
        ltt = lt(off)
        if 9*60 <= ltt < 17*60+30: return "REGULAR"
        return "CLOSED"

    # Europe/London → GMT/BST
    if any(x in tz for x in ["EUROPE/LONDON","EUROPE/DUBLIN"]):
        if wd >= 5: return "CLOSED"
        off = 1 if 3 <= mo <= 10 else 0
        ltt = lt(off)
        if 8*60 <= ltt < 16*60+30: return "REGULAR"
        return "CLOSED"

    # Europe/Berlin / Zurich → CET/CEST
    if any(x in tz for x in ["EUROPE/BERLIN","EUROPE/ZURICH","EUROPE/VIENNA"]):
        if wd >= 5: return "CLOSED"
        off = 2 if 3 <= mo <= 10 else 1
        ltt = lt(off)
        if 9*60 <= ltt < 17*60+30: return "REGULAR"
        return "CLOSED"

    # Asia/Tokyo → UTC+9
    if "ASIA/TOKYO" in tz:
        if wd >= 5: return "CLOSED"
        ltt = lt(9)
        if 9*60 <= ltt < 11*60+30 or 12*60+30 <= ltt < 15*60+30: return "REGULAR"
        return "CLOSED"

    # Asia/Hong_Kong → UTC+8
    if any(x in tz for x in ["ASIA/HONG_KONG","ASIA/SHANGHAI","ASIA/SINGAPORE"]):
        if wd >= 5: return "CLOSED"
        ltt = lt(8)
        if 9*60+30 <= ltt < 16*60: return "REGULAR"
        return "CLOSED"

    # ── Fallback: exchange name string matching ───────────────────────────────
    # US — short codes AND full exchange names Yahoo may return
    if any(x in exch for x in ["NYSE","NYQ","NYM","NYB","NYF","NASDAQ","NMS","NGM","NCM",
                                "NASDAQGS","NASDAQGM","NASDAQCM","BATS","ARCA","PCX",
                                "ASE","CBOE","NEW YORK STOCK","AMERICAN STOCK","NASDAQ GLOBAL"]):
        if wd >= 5: return "CLOSED"
        off = -4 if 3 <= mo <= 11 else -5
        ltt = lt(off)
        if   4*60    <= ltt < 9*60+30:  return "PRE"
        elif 9*60+30 <= ltt < 16*60:    return "REGULAR"
        elif 16*60   <= ltt < 20*60:    return "POST"
        return "CLOSED"

    # Dubai
    if any(x in exch for x in ["DUBAI","DFM","ADX","ABU DHABI","NASDAQ DUBAI"]):
        if wd >= 5: return "CLOSED"
        ltt = lt(4)
        if 10*60 <= ltt < 14*60+30: return "REGULAR"
        return "CLOSED"

    # Euronext
    if any(x in exch for x in ["PARIS","EURONEXT","SBF","AMS","AMSTERDAM","BRUSSELS"]):
        if wd >= 5: return "CLOSED"
        off = 2 if 3 <= mo <= 10 else 1
        ltt = lt(off)
        if 9*60 <= ltt < 17*60+30: return "REGULAR"
        return "CLOSED"

    # LSE
    if any(x in exch for x in ["LSE","LONDON","IOB","LSEETF"]):
        if wd >= 5: return "CLOSED"
        off = 1 if 3 <= mo <= 10 else 0
        ltt = lt(off)
        if 8*60 <= ltt < 16*60+30: return "REGULAR"
        return "CLOSED"

    # Frankfurt / Xetra
    if any(x in exch for x in ["XETRA","FRANKFURT","ETR","IBIS"]):
        if wd >= 5: return "CLOSED"
        off = 2 if 3 <= mo <= 10 else 1
        ltt = lt(off)
        if 9*60 <= ltt < 17*60+30: return "REGULAR"
        return "CLOSED"

    return None   # truly unknown — keep Yahoo's value


def _fetch_yahoo_quotes(symbols: list[str]) -> dict[str, dict]:
    """
    Batch-fetch live quotes via Yahoo Finance v7 quote API.
    Market state is overridden by _calc_market_state() for accuracy.
    Falls back per-symbol to v8 chart API on partial failure.
    """
    if not symbols:
        return {}

    headers = {"User-Agent": "Mozilla/5.0"}
    out: dict[str, dict] = {}

    # ── v7 batch (up to 50 symbols per request) ──────────────────────────────
    BATCH = 50
    for i in range(0, len(symbols), BATCH):
        batch = [s.upper() for s in symbols[i:i + BATCH]]
        joined = ",".join(batch)
        url = (
            f"https://query1.finance.yahoo.com/v7/finance/quote"
            f"?symbols={joined}"
            f"&fields=regularMarketPrice,regularMarketPreviousClose,"
            f"regularMarketChange,regularMarketChangePercent,"
            f"regularMarketVolume,bid,ask,currency,marketState,"
            f"fullExchangeName,exchangeTimezoneName,shortName"
        )
        try:
            with httpx.Client(timeout=10.0, headers=headers) as c:
                r = c.get(url); r.raise_for_status()
            for q in r.json().get("quoteResponse", {}).get("result", []):
                sym   = q.get("symbol", "").upper()
                price = float(q.get("regularMarketPrice", 0) or 0)
                prev  = float(q.get("regularMarketPreviousClose", price) or price)
                chg   = float(q.get("regularMarketChange", price - prev) or (price - prev))
                pct   = float(q.get("regularMarketChangePercent", 0) or 0)
                bid   = q.get("bid")
                ask   = q.get("ask")
                out[sym] = {
                    "symbol":       sym,
                    "name":         q.get("shortName", sym),
                    "last":         price,
                    "bid":          float(bid) if bid and float(bid) > 0 else None,
                    "ask":          float(ask) if ask and float(ask) > 0 else None,
                    "change":       round(chg, 4),
                    "change_pct":   round(pct, 4),
                    "volume":       q.get("regularMarketVolume"),
                    "currency":     q.get("currency", "USD"),
                    "market_state": q.get("marketState", "CLOSED"),
                    "exchange":     q.get("fullExchangeName", ""),
                    "exchange_tz":  q.get("exchangeTimezoneName", ""),
                }
        except Exception as e:
            logger.warning(f"Yahoo v7 batch fetch failed for {batch}: {e}")

    # ── Fallback: v8 chart API for any symbols that failed ───────────────────
    missing = [s.upper() for s in symbols if s.upper() not in out]
    if missing:
        def _chart_fallback(sym: str) -> dict | None:
            url = f"https://query1.finance.yahoo.com/v8/finance/chart/{sym}?interval=1d&range=1d"
            try:
                with httpx.Client(timeout=8.0, headers=headers) as c:
                    r = c.get(url); r.raise_for_status()
                meta = r.json()["chart"]["result"][0]["meta"]
                price = float(meta.get("regularMarketPrice", 0))
                prev  = float(meta.get("chartPreviousClose", price) or price)
                chg   = price - prev
                pct   = (chg / prev * 100) if prev else 0.0
                return {
                    "symbol":       sym,
                    "name":         meta.get("shortName", sym),
                    "last":         price,
                    "bid":          None,
                    "ask":          None,
                    "change":       round(chg, 4),
                    "change_pct":   round(pct, 2),
                    "volume":       meta.get("regularMarketVolume"),
                    "currency":     meta.get("currency", "USD"),
                    "market_state": meta.get("marketState", "CLOSED"),
                    "exchange":     meta.get("exchangeName", ""),
                }
            except Exception as e2:
                logger.warning(f"Yahoo chart fallback failed for {sym}: {e2}")
                return None

        with ThreadPoolExecutor(max_workers=min(len(missing), 10)) as ex:
            futures = {ex.submit(_chart_fallback, s): s for s in missing}
            for fut in as_completed(futures):
                result = fut.result()
                if result:
                    out[result["symbol"]] = result

    # ── Override market_state with local hours calculation ────────────────────
    for sym, q in out.items():
        override = _calc_market_state(q.get("exchange", ""), q.get("exchange_tz", ""))
        if override is not None:
            q["market_state"] = override

    return out


def _fetch_sparkline(symbol: str) -> list[float]:
    """Fetch ~30 intraday data points for sparkline (1-day, 5-min interval)."""
    sym = symbol.upper()
    url = f"https://query1.finance.yahoo.com/v8/finance/chart/{sym}?interval=5m&range=1d"
    try:
        with httpx.Client(timeout=8.0, headers={"User-Agent": "Mozilla/5.0"}) as c:
            r = c.get(url); r.raise_for_status()
            data = r.json()
        closes = data["chart"]["result"][0]["indicators"]["quote"][0].get("close", [])
        # filter None values, keep up to 30 points, evenly sampled
        closes = [float(p) for p in closes if p is not None]
        if len(closes) > 30:
            step = len(closes) // 30
            closes = closes[::step][:30]
        return closes
    except Exception:
        return []


@app.post("/market/quotes")
def market_quotes(
    payload: dict,
    user_id: str = Depends(require_user_id),
):
    """Batch-fetch live quotes for a list of symbols."""
    symbols = [s.upper() for s in payload.get("symbols", []) if s][:50]
    if not symbols:
        return {"quotes": []}
    now = time.time()
    # check cache
    fresh = {s: _QUOTE_CACHE[s] for s in symbols if s in _QUOTE_CACHE and now - _QUOTE_CACHE[s]["_ts"] < _QUOTE_CACHE_TTL}
    stale = [s for s in symbols if s not in fresh]
    if stale:
        fetched = _fetch_yahoo_quotes(stale)
        for sym, q in fetched.items():
            q["_ts"] = now
            _QUOTE_CACHE[sym] = q
            fresh[sym] = q
    return {"quotes": [v for k, v in fresh.items() if not k.startswith("_")]}


@app.get("/market/sparkline/{symbol}")
def market_sparkline(symbol: str, user_id: str = Depends(require_user_id)):
    """Return intraday sparkline data points for a symbol."""
    return {"symbol": symbol.upper(), "prices": _fetch_sparkline(symbol)}


@app.get("/market/data")
def market_data(profile_id: Optional[str] = Query(None),
                user_id: str = Depends(require_user_id), db: Session = Depends(get_db)):
    """
    Returns live quotes for all user's held symbols + watchlist,
    merged with their position quantity and avg cost.
    """
    # 1. Holdings
    all_accounts = db.query(models.Account).filter_by(user_id=user_id).all()
    all_ids = {a.id for a in all_accounts}
    profile_filter = _profile_account_ids(profile_id, user_id, all_ids, db)
    accounts = all_accounts if profile_filter is None else [a for a in all_accounts if a.id in profile_filter]
    account_ids = [a.id for a in accounts]
    holdings = (
        db.query(models.Holding, models.Asset)
        .join(models.Asset, models.Holding.asset_id == models.Asset.id)
        .filter(models.Holding.account_id.in_(account_ids))
        .all()
    )
    # map symbol → {qty, avg_cost, asset_class, quote_currency}
    # When the same symbol is held across multiple brokers, combine with a
    # weighted-average cost so that POSITION and AVG PRICE are both correct.
    position_map: dict[str, dict] = {}
    for h, asset in holdings:
        sym = asset.symbol.upper()
        qty = h.quantity or 0.0
        if abs(qty) <= 1e-8:
            continue
        if sym in position_map:
            old_qty = position_map[sym]["quantity"]
            old_avg = position_map[sym]["avg_cost"]
            new_avg = h.avg_cost or 0.0
            combined_qty = old_qty + qty
            # Weighted average: (old_shares * old_avg + new_shares * new_avg) / total
            if combined_qty > 1e-8:
                position_map[sym]["avg_cost"] = (old_qty * old_avg + qty * new_avg) / combined_qty
            position_map[sym]["quantity"] = combined_qty
        else:
            position_map[sym] = {
                "quantity": qty,
                "avg_cost": h.avg_cost or 0.0,
                "asset_class": asset.asset_class,
                "quote_currency": asset.quote_currency,
            }

    # 2. Watchlist
    wl_items = db.query(models.WatchlistItem).filter_by(user_id=user_id).all()
    watchlist_syms = [w.symbol.upper() for w in wl_items]

    # 3. Union
    all_symbols = list({*position_map.keys(), *watchlist_syms})
    # exclude pure fiat (3-letter ISO that are likely currency codes, not tickers)
    fiat_like = {"USD", "EUR", "GBP", "CHF", "JPY", "AUD", "CAD", "SGD", "HKD", "NZD",
                 "NOK", "SEK", "DKK", "CZK", "PLN", "HUF", "RON", "BGN", "HRK", "TRY",
                 "ZAR", "BRL", "MXN", "INR", "CNY", "KRW", "AED", "SAR", "QAR", "KWD"}
    all_symbols = [s for s in all_symbols if s not in fiat_like]

    if not all_symbols:
        return {"quotes": [], "watchlist": watchlist_syms}

    # 4. Separate crypto held symbols from stock symbols
    crypto_held = {s for s in all_symbols if position_map.get(s, {}).get("asset_class") == "crypto"}
    stock_syms  = [s for s in all_symbols if s not in crypto_held]

    # 4a. Fetch stock/ETF quotes from Yahoo Finance
    now = time.time()
    fresh = {s: _QUOTE_CACHE[s] for s in stock_syms if s in _QUOTE_CACHE and now - _QUOTE_CACHE[s]["_ts"] < _QUOTE_CACHE_TTL}
    stale = [s for s in stock_syms if s not in fresh]
    if stale:
        fetched = _fetch_yahoo_quotes(stale)
        for sym, q in fetched.items():
            q["_ts"] = now
            _QUOTE_CACHE[sym] = q
            fresh[sym] = q

    # 4b. Build crypto quotes from CoinGecko (real prices, not ETF proxies)
    crypto_prices = _fetch_crypto_prices()
    crypto_meta   = _crypto_cache.get("meta", {})
    for sym in crypto_held:
        price = crypto_prices.get(sym)
        if price is None:
            continue
        cm = crypto_meta.get(sym, {})
        fresh[sym] = {
            "symbol":       sym,
            "name":         cm.get("name", sym),
            "last":         price,
            "bid":          None,
            "ask":          None,
            "change":       cm.get("change", 0.0),
            "change_pct":   cm.get("change_pct", 0.0),
            "volume":       None,
            "currency":     "USD",
            "market_state": "REGULAR",   # crypto never closes
            "exchange":     "CCC",
            "image_url":    cm.get("image", ""),
        }

    # 5. Merge positions
    quotes = []
    for sym in all_symbols:
        q = fresh.get(sym)
        if not q:
            continue
        out = {k: v for k, v in q.items() if not k.startswith("_")}
        if sym in position_map:
            out["position"]      = position_map[sym]["quantity"]
            out["avg_price"]     = position_map[sym]["avg_cost"]
            out["asset_class"]   = position_map[sym]["asset_class"]
            out["quote_currency"]= position_map[sym]["quote_currency"]
        else:
            out["position"]      = None
            out["avg_price"]     = None
            out["asset_class"]   = out.get("asset_class")
            out["quote_currency"]= out.get("quote_currency")
        out["in_watchlist"] = sym in watchlist_syms
        quotes.append(out)

    # Recalculate market_state for stocks (crypto already set to REGULAR above)
    for q in quotes:
        if q.get("exchange") == "CCC":
            continue   # crypto — always open
        override = _calc_market_state(q.get("exchange", ""), q.get("exchange_tz", ""))
        if override is not None:
            q["market_state"] = override

    quotes.sort(key=lambda q: q["symbol"])
    return {"quotes": quotes, "watchlist": watchlist_syms}


@app.get("/market/watchlist")
def get_watchlist(user_id: str = Depends(require_user_id), db: Session = Depends(get_db)):
    items = db.query(models.WatchlistItem).filter_by(user_id=user_id).order_by(models.WatchlistItem.added_at).all()
    return {"symbols": [i.symbol for i in items]}


@app.post("/market/watchlist")
def add_watchlist(payload: dict, user_id: str = Depends(require_user_id), db: Session = Depends(get_db)):
    symbol = payload.get("symbol", "").upper().strip()
    if not symbol:
        raise HTTPException(400, "symbol required")
    existing = db.query(models.WatchlistItem).filter_by(user_id=user_id, symbol=symbol).first()
    if existing:
        return {"status": "exists", "symbol": symbol}
    item = models.WatchlistItem(
        id=str(uuid4()), user_id=user_id, symbol=symbol,
        added_at=datetime.now(timezone.utc).isoformat()
    )
    db.add(item); db.commit()
    return {"status": "added", "symbol": symbol}


@app.delete("/market/watchlist/{symbol}")
def remove_watchlist(symbol: str, user_id: str = Depends(require_user_id), db: Session = Depends(get_db)):
    item = db.query(models.WatchlistItem).filter_by(user_id=user_id, symbol=symbol.upper()).first()
    if not item:
        raise HTTPException(404, "Not in watchlist")
    db.delete(item); db.commit()
    return {"status": "removed", "symbol": symbol.upper()}


# ── Forex ──────────────────────────────────────────────────────────────────

_FOREX_PAIRS = [
    ("EURUSD=X", "EUR/USD"),
    ("GBPUSD=X", "GBP/USD"),
    ("USDJPY=X", "USD/JPY"),
    ("USDCHF=X", "USD/CHF"),
    ("AUDUSD=X", "AUD/USD"),
    ("USDCAD=X", "USD/CAD"),
    ("GBPEUR=X", "GBP/EUR"),
    ("EURGBP=X", "EUR/GBP"),
    ("EURJPY=X", "EUR/JPY"),
    ("EURCHF=X", "EUR/CHF"),
    ("USDAED=X", "USD/AED"),
    ("USDSGD=X", "USD/SGD"),
    ("USDPLN=X", "USD/PLN"),
    ("USDNOK=X", "USD/NOK"),
    ("USDSEK=X", "USD/SEK"),
]

# Synthetic inverse pairs — computed from their source pair
_SYNTHETIC_PAIRS = {
    "USDEUR": "EURUSD=X",   # 1 / EUR/USD
}

@app.get("/market/forex")
def market_forex(user_id: str = Depends(require_user_id)):
    """Live rates for major forex pairs."""
    symbols = [p[0] for p in _FOREX_PAIRS]
    name_map = {p[0]: p[1] for p in _FOREX_PAIRS}
    now = time.time()
    fresh = {s: _QUOTE_CACHE[s] for s in symbols if s in _QUOTE_CACHE and now - _QUOTE_CACHE[s]["_ts"] < _QUOTE_CACHE_TTL}
    stale = [s for s in symbols if s not in fresh]
    if stale:
        fetched = _fetch_yahoo_quotes(stale)
        for sym, q in fetched.items():
            q["_ts"] = now
            _QUOTE_CACHE[sym] = q
            fresh[sym] = q
    result = []
    for sym, display_name in _FOREX_PAIRS:
        q = fresh.get(sym)
        if not q:
            continue
        out = {k: v for k, v in q.items() if not k.startswith("_")}
        out["display_name"] = display_name
        result.append(out)

    # Add synthetic inverse pairs
    for synth_name, source_sym in _SYNTHETIC_PAIRS.items():
        src = fresh.get(source_sym)
        if not src or not src.get("last"):
            continue
        inv_last = 1.0 / src["last"] if src["last"] else 0
        inv_change = -src.get("change", 0) * (inv_last ** 2) if src.get("last") else 0
        inv_change_pct = -src.get("change_pct", 0)
        result.append({
            "symbol": synth_name,
            "name": f"{synth_name[:3]}/{synth_name[3:]}",
            "last": round(inv_last, 6),
            "change": round(inv_change, 6),
            "change_pct": round(inv_change_pct, 4),
            "currency": synth_name[3:],
            "market_state": src.get("market_state"),
            "display_name": f"{synth_name[:3]}/{synth_name[3:]}",
        })

    return {"pairs": result}


# ── News ────────────────────────────────────────────────────────────────────

@app.get("/market/news")
def market_news(symbols: str = "", user_id: str = Depends(require_user_id)):
    """Fetch latest news from Yahoo Finance for given symbols (comma-separated).
    ^GSPC and ^DJI are always included so major macro/geopolitical events that
    move the whole market (rate decisions, wars, trade policy) are never missed."""
    user_syms = [s.upper().strip() for s in symbols.split(",") if s.strip()]
    # Broad market symbols catch market-wide events even if not in user's portfolio
    market_wide = ["^GSPC", "^DJI", "^VIX"]
    # Combine, deduplicate, cap at 10 to avoid hammering Yahoo Finance
    seen_syms: set[str] = set()
    sym_list: list[str] = []
    for s in user_syms + market_wide:
        if s not in seen_syms:
            seen_syms.add(s); sym_list.append(s)
        if len(sym_list) >= 10:
            break
    seen: set[str] = set()
    articles: list[dict] = []
    headers = {"User-Agent": "Mozilla/5.0"}

    for sym in sym_list[:6]:
        try:
            url = (f"https://query2.finance.yahoo.com/v1/finance/search"
                   f"?q={sym}&quotesCount=0&newsCount=8&enableFuzzyQuery=false")
            with httpx.Client(timeout=6.0, headers=headers) as c:
                r = c.get(url)
                if r.status_code != 200:
                    continue
            for item in r.json().get("news", []):
                link = item.get("link", "")
                if not link or link in seen:
                    continue
                seen.add(link)
                thumb = None
                for res in item.get("thumbnail", {}).get("resolutions", []):
                    if res.get("width", 0) >= 100:
                        thumb = res.get("url"); break
                articles.append({
                    "title":        item.get("title", ""),
                    "link":         link,
                    "publisher":    item.get("publisher", ""),
                    "published_at": item.get("providerPublishTime", 0),
                    "thumbnail":    thumb,
                    "symbols":      item.get("relatedTickers", []),
                })
        except Exception as e:
            logger.warning(f"News fetch failed for {sym}: {e}")

    articles.sort(key=lambda a: a["published_at"], reverse=True)
    return {"articles": articles[:25]}


# ════════════════════════════════════════════════════════════════════════════
#  CRYPTO WALLET ENDPOINTS
# ════════════════════════════════════════════════════════════════════════════

@app.get("/wallets")
def list_wallets(user_id: str = Depends(require_user_id), db: Session = Depends(get_db)):
    rows = db.execute(
        text("SELECT id, chain, address, label, account_id, last_synced, created_at "
             "FROM crypto_wallets WHERE user_id = :uid ORDER BY created_at"),
        {"uid": user_id}
    ).fetchall()
    return {"wallets": [dict(r._mapping) for r in rows]}


@app.post("/wallets")
def add_wallet(payload: dict, user_id: str = Depends(require_user_id), db: Session = Depends(get_db)):
    chain      = (payload.get("chain") or "").upper().strip()
    address    = (payload.get("address") or "").strip()
    label      = (payload.get("label") or "").strip() or None
    account_id = (payload.get("account_id") or "").strip() or None

    if chain not in SUPPORTED_CHAINS:
        raise HTTPException(400, f"Unsupported chain. Supported: {', '.join(SUPPORTED_CHAINS)}")
    if not address:
        raise HTTPException(400, "Address required")

    # Validate account_id belongs to this user
    if account_id:
        acct = db.execute(
            text("SELECT id FROM accounts WHERE id = :id AND user_id = :uid"),
            {"id": account_id, "uid": user_id}
        ).fetchone()
        if not acct:
            raise HTTPException(404, "Account not found")

    # Check duplicate
    existing = db.execute(
        text("SELECT id FROM crypto_wallets WHERE user_id = :uid AND chain = :c AND address = :a"),
        {"uid": user_id, "c": chain, "a": address}
    ).fetchone()
    if existing:
        raise HTTPException(409, "Wallet already added")

    wid = str(uuid4())
    now = datetime.now(timezone.utc).isoformat()
    db.execute(
        text("INSERT INTO crypto_wallets (id, user_id, chain, address, label, account_id, created_at) "
             "VALUES (:id, :uid, :c, :a, :l, :acc, :ts)"),
        {"id": wid, "uid": user_id, "c": chain, "a": address, "l": label, "acc": account_id, "ts": now}
    )
    db.commit()
    return {"id": wid, "chain": chain, "address": address, "label": label, "account_id": account_id}


@app.delete("/wallets/{wallet_id}")
def delete_wallet(wallet_id: str, user_id: str = Depends(require_user_id), db: Session = Depends(get_db)):
    result = db.execute(
        text("DELETE FROM crypto_wallets WHERE id = :id AND user_id = :uid"),
        {"id": wallet_id, "uid": user_id}
    )
    db.commit()
    if result.rowcount == 0:
        raise HTTPException(404, "Wallet not found")
    return {"deleted": True}


@app.post("/wallets/{wallet_id}/sync")
def sync_wallet(wallet_id: str, user_id: str = Depends(require_user_id), db: Session = Depends(get_db)):
    row = db.execute(
        text("SELECT chain, address, account_id FROM crypto_wallets WHERE id = :id AND user_id = :uid"),
        {"id": wallet_id, "uid": user_id}
    ).fetchone()
    if not row:
        raise HTTPException(404, "Wallet not found")

    holdings = _wallet_to_holdings(row.chain, row.address)
    now = datetime.now(timezone.utc).isoformat()
    db.execute(
        text("UPDATE crypto_wallets SET last_synced = :ts WHERE id = :id"),
        {"ts": now, "id": wallet_id}
    )

    # If linked to an account, write holdings into the portfolio
    if row.account_id:
        for h in holdings:
            sym = h["symbol"].upper()
            asset_class = "crypto" if row.chain not in ("ETH", "BNB", "MATIC", "SOL") or sym not in ("USDT", "USDC", "BUSD", "DAI", "TUSD") else "crypto"
            asset = db.query(models.Asset).filter(models.Asset.symbol == sym).first()
            if not asset:
                asset = models.Asset(id=str(uuid4()), symbol=sym, name=h.get("name", sym),
                                     asset_class="crypto", quote_currency="USD")
                db.add(asset); db.flush()
            holding = db.query(models.Holding).filter(
                models.Holding.account_id == row.account_id,
                models.Holding.asset_id == asset.id
            ).first()
            qty = float(h.get("balance", 0))
            if not holding:
                holding = models.Holding(id=str(uuid4()), account_id=row.account_id,
                                         asset_id=asset.id, quantity=qty, avg_cost=0.0)
                db.add(holding)
            else:
                holding.quantity = qty

    db.commit()
    return {
        "wallet_id":   wallet_id,
        "chain":       row.chain,
        "address":     row.address,
        "holdings":    holdings,
        "total_usd":   sum(h["value_usd"] for h in holdings),
        "synced_at":   now,
        "account_id":  row.account_id,
    }


@app.get("/wallets/balances")
def all_wallet_balances(user_id: str = Depends(require_user_id), db: Session = Depends(get_db)):
    """Fetch live balances for all user wallets in parallel."""
    rows = db.execute(
        text("SELECT id, chain, address, label FROM crypto_wallets WHERE user_id = :uid"),
        {"uid": user_id}
    ).fetchall()

    def _sync_one(row):
        holdings = _wallet_to_holdings(row.chain, row.address)
        return {
            "wallet_id": row.id,
            "chain":     row.chain,
            "address":   row.address,
            "label":     row.label,
            "holdings":  holdings,
            "total_usd": sum(h["value_usd"] for h in holdings),
        }

    results = []
    with ThreadPoolExecutor(max_workers=min(len(rows), 6)) as ex:
        futures = {ex.submit(_sync_one, r): r for r in rows}
        for fut in as_completed(futures):
            try:
                results.append(fut.result())
            except Exception as e:
                logger.warning(f"Wallet sync failed: {e}")

    return {"wallets": results, "total_usd": sum(w["total_usd"] for w in results)}
