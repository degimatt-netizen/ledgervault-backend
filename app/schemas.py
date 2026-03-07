from pydantic import BaseModel
from typing import List, Literal, Optional


AccountType = Literal["bank", "exchange", "broker", "crypto_wallet", "cash"]
AssetClass = Literal["fiat", "crypto", "stock", "etf", "commodity", "custom"]
EventType = Literal["income", "expense", "transfer", "conversion", "trade"]


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
# Transaction Engine v3
# -------------------------

class TransactionLegCreate(BaseModel):
    account_id: str
    asset_id: str
    quantity: float
    unit_price: Optional[float] = None
    fee_flag: bool = False


class TransactionLegOut(BaseModel):
    id: str
    event_id: str
    account_id: str
    asset_id: str
    quantity: float
    unit_price: Optional[float] = None
    fee_flag: str


class TransactionLegList(BaseModel):
    items: List[TransactionLegOut]


class TransactionEventCreate(BaseModel):
    event_type: EventType
    category: Optional[str] = None
    description: Optional[str] = None
    date: str
    note: Optional[str] = None
    source: str = "manual"
    external_id: Optional[str] = None
    legs: List[TransactionLegCreate]


class TransactionEventOut(BaseModel):
    id: str
    event_type: str
    category: Optional[str] = None
    description: Optional[str] = None
    date: str
    note: Optional[str] = None
    source: str
    external_id: Optional[str] = None


class TransactionEventList(BaseModel):
    items: List[TransactionEventOut]

