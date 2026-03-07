from pydantic import BaseModel
from typing import List, Literal, Optional


AccountType = Literal["bank", "exchange", "broker", "crypto_wallet", "cash"]
AssetClass = Literal["fiat", "crypto", "stock", "etf", "commodity", "custom"]
TransactionType = Literal["deposit", "withdrawal", "buy", "sell", "transfer_in", "transfer_out"]


# -------------------------
# Accounts
# -------------------------

class AccountBase(BaseModel):
    name: str
    account_type: AccountType
    base_currency: str


class AccountCreate(AccountBase):
    pass


class AccountUpdate(BaseModel):
    name: Optional[str] = None
    account_type: Optional[AccountType] = None
    base_currency: Optional[str] = None


class AccountOut(AccountBase):
    id: str


class AccountList(BaseModel):
    items: List[AccountOut]


# -------------------------
# Assets
# -------------------------

class AssetBase(BaseModel):
    symbol: str
    name: str
    asset_class: AssetClass
    quote_currency: str


class AssetCreate(AssetBase):
    pass


class AssetOut(AssetBase):
    id: str


class AssetList(BaseModel):
    items: List[AssetOut]


# -------------------------
# Holdings
# -------------------------

class HoldingBase(BaseModel):
    account_id: str
    asset_id: str
    quantity: float
    avg_cost: float


class HoldingOut(HoldingBase):
    id: str


class HoldingList(BaseModel):
    items: List[HoldingOut]


# -------------------------
# Transactions
# -------------------------

class TransactionBase(BaseModel):
    account_id: str
    asset_id: str
    type: TransactionType
    quantity: float
    price: Optional[float] = None
    fee: float = 0.0
    fee_currency: Optional[str] = None
    total_value: float
    note: Optional[str] = None


class TransactionCreate(TransactionBase):
    pass


class TransactionOut(TransactionBase):
    id: str


class TransactionList(BaseModel):
    items: List[TransactionOut]

