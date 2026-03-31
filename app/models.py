from sqlalchemy import Column, String, Float, Boolean, ForeignKey, Text
from app.db import Base


class User(Base):
    __tablename__ = "users"

    id              = Column(String, primary_key=True, index=True)
    email           = Column(String, unique=True, nullable=False, index=True)
    phone           = Column(String, unique=True, nullable=True, index=True)
    password_hash   = Column(String, nullable=True)
    name            = Column(String, nullable=True)
    is_verified     = Column(Boolean, nullable=False, default=False)
    verify_code     = Column(String, nullable=True)
    verify_expires  = Column(String, nullable=True)   # ISO datetime string
    reset_code      = Column(String, nullable=True)
    reset_expires   = Column(String, nullable=True)   # ISO datetime string
    apple_user_id   = Column(String, unique=True, nullable=True)
    google_sub      = Column(String, unique=True, nullable=True)
    created_at      = Column(String, nullable=False)
    logout_at       = Column(String, nullable=True)   # ISO datetime; tokens issued before this are revoked
    totp_secret     = Column(String, nullable=True)   # base32 TOTP secret (only set when TOTP is enabled)
    totp_enabled    = Column(Boolean, nullable=False, default=False)


class Account(Base):
    __tablename__ = "accounts"

    id = Column(String, primary_key=True, index=True)
    user_id = Column(String, nullable=True, index=True)  # null = guest / legacy
    name = Column(String, nullable=False)
    account_type = Column(String, nullable=False)   # bank, exchange, broker, crypto_wallet, cash
    base_currency = Column(String, nullable=False)
    exclude_from_total = Column(Boolean, nullable=False, default=False)


class Asset(Base):
    __tablename__ = "assets"

    id = Column(String, primary_key=True, index=True)
    symbol = Column(String, nullable=False, unique=True)
    name = Column(String, nullable=False)
    asset_class = Column(String, nullable=False)    # fiat, crypto, stock, etf, commodity, custom
    quote_currency = Column(String, nullable=False)


class Holding(Base):
    __tablename__ = "holdings"

    id = Column(String, primary_key=True, index=True)
    account_id = Column(String, ForeignKey("accounts.id"), nullable=False)
    asset_id = Column(String, ForeignKey("assets.id"), nullable=False)
    quantity = Column(Float, nullable=False, default=0.0)
    avg_cost = Column(Float, nullable=False, default=0.0)


class TransactionEvent(Base):
    __tablename__ = "transaction_events"

    id = Column(String, primary_key=True, index=True)
    event_type = Column(String, nullable=False)     # income, expense, transfer, conversion, trade
    category = Column(String, nullable=True)
    description = Column(String, nullable=True)
    date = Column(String, nullable=False)           # ISO date string for now
    note = Column(String, nullable=True)

    source = Column(String, nullable=False, default="manual")   # manual, api, imported
    external_id = Column(String, nullable=True)
    created_at = Column(String, nullable=True)   # ISO datetime; set on insert for correct sort order


class TransactionLeg(Base):
    __tablename__ = "transaction_legs"

    id = Column(String, primary_key=True, index=True)
    event_id = Column(String, ForeignKey("transaction_events.id"), nullable=False)

    account_id = Column(String, ForeignKey("accounts.id"), nullable=False)
    asset_id = Column(String, ForeignKey("assets.id"), nullable=False)

    quantity = Column(Float, nullable=False)        # negative = outflow, positive = inflow
    unit_price = Column(Float, nullable=True)       # optional cost basis / price
    fee_flag = Column(String, nullable=False, default="false")  # "true" / "false"


class ExchangeConnection(Base):
    __tablename__ = "exchange_connections"

    id = Column(String, primary_key=True, index=True)
    user_id = Column(String, nullable=True, index=True)   # null = legacy pre-auth row
    exchange = Column(String, nullable=False)       # binance, kraken, coinbase, bybit, kucoin, okx
    name = Column(String, nullable=False)           # user-defined label
    api_key = Column(String, nullable=False)
    api_secret = Column(String, nullable=False)
    passphrase = Column(String, nullable=True)      # required by KuCoin, OKX
    account_id = Column(String, ForeignKey("accounts.id"), nullable=True)  # optional linked account
    last_synced = Column(String, nullable=True)     # ISO datetime string
    status = Column(String, nullable=False, default="active")  # active, error, inactive
    status_message = Column(String, nullable=True)


class BankConnection(Base):
    __tablename__ = "bank_connections"

    id = Column(String, primary_key=True, index=True)
    user_id = Column(String, nullable=True, index=True)   # null = legacy pre-auth row
    provider = Column(String, nullable=True, default="truelayer")  # "truelayer" | "saltedge"
    provider_id = Column(String, nullable=False)            # "uk-ob-revolut" | "revolut_eu"
    provider_name = Column(String, nullable=False)          # "Revolut"
    account_display_name = Column(String, nullable=False)   # "Current Account"
    account_type = Column(String, nullable=True)            # "TRANSACTION", "SAVINGS"
    currency = Column(String, nullable=True)                # "GBP", "EUR", …
    truelayer_account_id = Column(String, nullable=False, unique=True)  # TrueLayer acct ID or "se:{saltedge_acct_id}"
    saltedge_connection_id = Column(String, nullable=True)  # Salt Edge connection_id
    access_token = Column(Text, nullable=False)
    refresh_token = Column(Text, nullable=True)
    ledger_account_id = Column(String, ForeignKey("accounts.id"), nullable=True)
    last_synced = Column(String, nullable=True)
    status = Column(String, nullable=False, default="active")
    status_message = Column(String, nullable=True)


class SnaptradeConnection(Base):
    __tablename__ = "snaptrade_connections"

    id                  = Column(String, primary_key=True, index=True)
    user_id             = Column(String, nullable=False, index=True)
    snaptrade_user_id   = Column(String, nullable=False)   # userId sent to SnapTrade
    snaptrade_secret    = Column(String, nullable=False)   # userSecret from SnapTrade (encrypted)
    brokerage_name      = Column(String, nullable=True)    # e.g. "Alpaca", "Robinhood"
    brokerage_id        = Column(String, nullable=True)    # SnapTrade brokerage ID
    authorization_id    = Column(String, nullable=True)    # SnapTrade authorization ID
    account_id          = Column(String, ForeignKey("accounts.id"), nullable=True)
    status              = Column(String, nullable=False, default="active")
    status_message      = Column(String, nullable=True)
    last_synced         = Column(String, nullable=True)


class VezgoConnection(Base):
    __tablename__ = "vezgo_connections"

    id              = Column(String, primary_key=True, index=True)
    user_id         = Column(String, nullable=False, index=True)
    vezgo_user_id   = Column(String, nullable=False)
    vezgo_token     = Column(String, nullable=True)         # encrypted access token
    account_name    = Column(String, nullable=True)         # e.g. "Bitpanda"
    account_id      = Column(String, ForeignKey("accounts.id"), nullable=True)
    status          = Column(String, nullable=False, default="active")
    status_message  = Column(String, nullable=True)
    last_synced     = Column(String, nullable=True)


class FlanksBrokerConnection(Base):
    __tablename__ = "flanks_connections"

    id              = Column(String, primary_key=True, index=True)
    user_id         = Column(String, nullable=False, index=True)
    broker_id       = Column(String, nullable=False)        # e.g. "trade-republic"
    broker_name     = Column(String, nullable=True)
    flanks_user_id  = Column(String, nullable=True)
    account_id      = Column(String, ForeignKey("accounts.id"), nullable=True)
    status          = Column(String, nullable=False, default="active")
    status_message  = Column(String, nullable=True)
    last_synced     = Column(String, nullable=True)


class RecurringTransaction(Base):
    __tablename__ = "recurring_transactions"

    id = Column(String, primary_key=True, index=True)
    user_id = Column(String, nullable=True, index=True)   # null = legacy pre-auth row
    name = Column(String, nullable=False)
    event_type = Column(String, nullable=False)     # income, expense, transfer, trade
    category = Column(String, nullable=True)
    description = Column(String, nullable=True)
    note = Column(String, nullable=True)

    # Source leg (debit side)
    from_account_id = Column(String, ForeignKey("accounts.id"), nullable=False)
    from_asset_id = Column(String, ForeignKey("assets.id"), nullable=True)
    from_quantity = Column(Float, nullable=False)

    # Destination leg (credit side, optional for expense)
    to_account_id = Column(String, ForeignKey("accounts.id"), nullable=True)
    to_asset_id = Column(String, ForeignKey("assets.id"), nullable=True)
    to_quantity = Column(Float, nullable=True)

    unit_price = Column(Float, nullable=True)

    frequency = Column(String, nullable=False)      # daily, weekly, monthly, quarterly
    start_date = Column(String, nullable=False)     # ISO date string
    last_run_date = Column(String, nullable=True)
    next_run_date = Column(String, nullable=False)

    enabled = Column(Boolean, nullable=False, default=True)


class WatchlistItem(Base):
    __tablename__ = "watchlist"

    id        = Column(String, primary_key=True, index=True)
    user_id   = Column(String, nullable=False, index=True)
    symbol    = Column(String, nullable=False)
    added_at  = Column(String, nullable=True)
