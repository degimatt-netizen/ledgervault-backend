from pydantic import BaseModel
from typing import List, Literal, Optional


# -------------------------
# Auth
# -------------------------

class RegisterRequest(BaseModel):
    name: str
    email: str
    password: str

class LoginRequest(BaseModel):
    email: str
    password: str
    totp_code: Optional[str] = None   # 6-digit TOTP code, required when TOTP is enabled

class VerifyEmailRequest(BaseModel):
    email: str
    code: str

class ResendCodeRequest(BaseModel):
    email: str

class ForgotPasswordRequest(BaseModel):
    email: str

class ResetPasswordRequest(BaseModel):
    email: str
    code: str
    new_password: str

class SocialAuthRequest(BaseModel):
    provider: str                   # "apple" | "google"
    email: str
    name: str = ""
    apple_user_id: str = ""
    google_sub: str = ""

class AuthResponse(BaseModel):
    status: str                     # "ok" | "needs_verification" | "totp_required"
    access_token: Optional[str] = None
    user_id: Optional[str] = None
    email: Optional[str] = None
    name: Optional[str] = None
    message: Optional[str] = None
    is_new_user: Optional[bool] = None
    totp_required: Optional[bool] = None   # true when TOTP challenge needed on login

class TotpSetupResponse(BaseModel):
    secret: str             # base32 secret for manual entry
    uri: str                # otpauth:// URI for QR code generation

class TotpVerifyRequest(BaseModel):
    code: str               # 6-digit TOTP code

class TotpStatusResponse(BaseModel):
    enabled: bool

class UpdateProfileRequest(BaseModel):
    phone: Optional[str] = None
    name: Optional[str] = None


AccountType = Literal["bank", "exchange", "broker", "crypto_wallet", "cash"]
AssetClass = Literal["fiat", "crypto", "stock", "etf", "commodity", "custom"]
EventType = Literal["income", "expense", "transfer", "conversion", "trade"]
ExchangeType = Literal["binance", "kraken", "coinbase", "bybit", "kucoin", "okx"]
FrequencyType = Literal["daily", "weekly", "monthly", "quarterly"]


# -------------------------
# Accounts
# -------------------------

class AccountBase(BaseModel):
    name: str
    account_type: AccountType
    base_currency: str
    exclude_from_total: bool = False


class AccountCreate(AccountBase):
    pass


class AccountUpdate(BaseModel):
    name: Optional[str] = None
    account_type: Optional[AccountType] = None
    base_currency: Optional[str] = None
    exclude_from_total: Optional[bool] = None


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
    asset_id: Optional[str] = None
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
    asset_id: Optional[str] = None
    quantity: float
    unit_price: Optional[float] = None
    fee_flag: bool = False


class TransactionLegOut(BaseModel):
    id: str
    event_id: str
    account_id: str
    asset_id: Optional[str] = None
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


class TransactionEventUpdate(BaseModel):
    event_type: Optional[EventType] = None
    category: Optional[str] = None
    description: Optional[str] = None
    date: Optional[str] = None
    note: Optional[str] = None


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


# -------------------------
# Exchange Connections
# -------------------------

class ExchangeConnectionCreate(BaseModel):
    exchange: ExchangeType
    name: str
    api_key: str
    api_secret: str
    passphrase: Optional[str] = None
    account_id: Optional[str] = None


class ExchangeConnectionOut(BaseModel):
    id: str
    exchange: str
    name: str
    api_key_masked: str          # only last 4 chars shown
    account_id: Optional[str] = None
    last_synced: Optional[str] = None
    status: str
    status_message: Optional[str] = None


class ExchangeConnectionList(BaseModel):
    items: List[ExchangeConnectionOut]


class SyncResult(BaseModel):
    imported: int
    skipped: int
    errors: List[str]
    status: str


# -------------------------
# Bank Connections (TrueLayer)
# -------------------------

class BankConnectionOut(BaseModel):
    id: str
    provider_id: str
    provider_name: str
    account_display_name: str
    account_type: Optional[str] = None
    currency: Optional[str] = None
    truelayer_account_id: str
    ledger_account_id: Optional[str] = None
    last_synced: Optional[str] = None
    status: str
    status_message: Optional[str] = None


class BankConnectionList(BaseModel):
    items: List[BankConnectionOut]


class BankAuthUrlResponse(BaseModel):
    auth_url: str
    state: str


class BankCallbackResponse(BaseModel):
    items: List[BankConnectionOut]


# -------------------------
# Recurring Transactions
# -------------------------

class RecurringTransactionCreate(BaseModel):
    name: str
    event_type: EventType
    category: Optional[str] = None
    description: Optional[str] = None
    note: Optional[str] = None

    from_account_id: str
    from_asset_id: Optional[str] = None
    from_quantity: float

    to_account_id: Optional[str] = None
    to_asset_id: Optional[str] = None
    to_quantity: Optional[float] = None

    unit_price: Optional[float] = None

    frequency: FrequencyType
    start_date: str
    next_run_date: str

    enabled: bool = True


class RecurringTransactionUpdate(BaseModel):
    name: Optional[str] = None
    enabled: Optional[bool] = None
    next_run_date: Optional[str] = None
    frequency: Optional[FrequencyType] = None
    from_quantity: Optional[float] = None
    to_quantity: Optional[float] = None
    unit_price: Optional[float] = None
    category: Optional[str] = None
    description: Optional[str] = None
    note: Optional[str] = None


class RecurringTransactionOut(BaseModel):
    id: str
    name: str
    event_type: str
    category: Optional[str] = None
    description: Optional[str] = None
    note: Optional[str] = None

    from_account_id: str
    from_asset_id: Optional[str] = None
    from_quantity: float

    to_account_id: Optional[str] = None
    to_asset_id: Optional[str] = None
    to_quantity: Optional[float] = None

    unit_price: Optional[float] = None

    frequency: str
    start_date: str
    last_run_date: Optional[str] = None
    next_run_date: str
    enabled: bool


class RecurringTransactionList(BaseModel):
    items: List[RecurringTransactionOut]


# -------------------------
# Account Profiles
# -------------------------

class AccountProfileCreate(BaseModel):
    name: str
    emoji: str = "👤"
    account_ids: List[str] = []


class AccountProfileUpdate(BaseModel):
    name: Optional[str] = None
    emoji: Optional[str] = None
    account_ids: Optional[List[str]] = None
    sort_order: Optional[int] = None


class AccountProfileOut(BaseModel):
    id: str
    name: str
    emoji: str
    account_ids: List[str]
    sort_order: Optional[int] = None


class AccountProfileList(BaseModel):
    items: List[AccountProfileOut]
