from pydantic import BaseModel
from typing import List, Literal, Optional

WalletKind = Literal["fiat", "crypto"]
TransactionType = Literal["deposit", "withdraw", "transfer_in", "transfer_out", "buy", "sell"]


class WalletBase(BaseModel):
    name: str
    kind: WalletKind
    currency: str
    balance: float


class WalletCreate(WalletBase):
    pass


class WalletUpdate(BaseModel):
    name: Optional[str] = None
    kind: Optional[WalletKind] = None
    currency: Optional[str] = None
    balance: Optional[float] = None


class WalletOut(WalletBase):
    id: str


class WalletList(BaseModel):
    items: List[WalletOut]


class TransactionBase(BaseModel):
    wallet_id: str
    type: TransactionType
    asset: Optional[str] = None
    amount: float
    price_per_unit: Optional[float] = None
    total_value: float
    currency: str
    note: Optional[str] = None


class TransactionCreate(TransactionBase):
    pass


class TransactionOut(TransactionBase):
    id: str


class TransactionList(BaseModel):
    items: List[TransactionOut]

class WalletOut(WalletBase):
    id: str

class WalletList(BaseModel):
    items: List[WalletOut]

