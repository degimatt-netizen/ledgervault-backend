from sqlalchemy import Column, String, Float, ForeignKey
from app.db import Base


class Account(Base):
    __tablename__ = "accounts"

    id = Column(String, primary_key=True, index=True)
    name = Column(String, nullable=False)
    account_type = Column(String, nullable=False)   # bank, exchange, broker, crypto_wallet, cash
    base_currency = Column(String, nullable=False)  # EUR, USD, etc


class Asset(Base):
    __tablename__ = "assets"

    id = Column(String, primary_key=True, index=True)
    symbol = Column(String, nullable=False, unique=True)      # EUR, BTC, AAPL
    name = Column(String, nullable=False)                     # Euro, Bitcoin, Apple
    asset_class = Column(String, nullable=False)              # fiat, crypto, stock, etf, commodity, custom
    quote_currency = Column(String, nullable=False)           # usually EUR or USD


class Holding(Base):
    __tablename__ = "holdings"

    id = Column(String, primary_key=True, index=True)
    account_id = Column(String, ForeignKey("accounts.id"), nullable=False)
    asset_id = Column(String, ForeignKey("assets.id"), nullable=False)

    quantity = Column(Float, nullable=False, default=0.0)
    avg_cost = Column(Float, nullable=False, default=0.0)


class Transaction(Base):
    __tablename__ = "transactions"

    id = Column(String, primary_key=True, index=True)
    account_id = Column(String, ForeignKey("accounts.id"), nullable=False)
    asset_id = Column(String, ForeignKey("assets.id"), nullable=False)

    type = Column(String, nullable=False)   # deposit, withdrawal, buy, sell, transfer_in, transfer_out
    quantity = Column(Float, nullable=False)
    price = Column(Float, nullable=True)
    fee = Column(Float, nullable=False, default=0.0)
    fee_currency = Column(String, nullable=True)
    total_value = Column(Float, nullable=False)
    note = Column(String, nullable=True)