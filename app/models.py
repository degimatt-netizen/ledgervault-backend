from sqlalchemy import Column, String, Float, Boolean, ForeignKey
from app.db import Base


class Account(Base):
    __tablename__ = "accounts"

    id = Column(String, primary_key=True, index=True)
    name = Column(String, nullable=False)
    account_type = Column(String, nullable=False)   # bank, exchange, broker, crypto_wallet, cash
    base_currency = Column(String, nullable=False)


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
    exchange = Column(String, nullable=False)       # binance, kraken, coinbase, bybit, kucoin, okx
    name = Column(String, nullable=False)           # user-defined label
    api_key = Column(String, nullable=False)
    api_secret = Column(String, nullable=False)
    passphrase = Column(String, nullable=True)      # required by KuCoin, OKX
    account_id = Column(String, ForeignKey("accounts.id"), nullable=True)  # optional linked account
    last_synced = Column(String, nullable=True)     # ISO datetime string
    status = Column(String, nullable=False, default="active")  # active, error, inactive
    status_message = Column(String, nullable=True)


class RecurringTransaction(Base):
    __tablename__ = "recurring_transactions"

    id = Column(String, primary_key=True, index=True)
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
