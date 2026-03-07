from sqlalchemy import Column, String, Float, ForeignKey
from app.db import Base


class Wallet(Base):
    __tablename__ = "wallets"

    id = Column(String, primary_key=True, index=True)
    name = Column(String, nullable=False)
    kind = Column(String, nullable=False)      # "fiat" or "crypto"
    currency = Column(String, nullable=False)
    balance = Column(Float, nullable=False, default=0.0)


class Transaction(Base):
    __tablename__ = "transactions"

    id = Column(String, primary_key=True, index=True)
    wallet_id = Column(String, ForeignKey("wallets.id"), nullable=False)

    type = Column(String, nullable=False)      # deposit, withdraw, buy, sell, transfer_in, transfer_out
    asset = Column(String, nullable=True)      # BTC, ETH, TSLA, or null for fiat movements
    amount = Column(Float, nullable=False)     # units or money depending on type
    price_per_unit = Column(Float, nullable=True)
    total_value = Column(Float, nullable=False)
    currency = Column(String, nullable=False)  # EUR, USD, BTC etc
    note = Column(String, nullable=True)