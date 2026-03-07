from uuid import uuid4

from fastapi import FastAPI, Depends, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy.orm import Session

from app.db import engine, SessionLocal
from app import models
from app.schemas import (
    AccountList, AccountOut, AccountCreate, AccountUpdate,
    AssetList, AssetOut, AssetCreate,
    HoldingList, HoldingOut,
    TransactionList, TransactionOut, TransactionCreate
)

app = FastAPI(title="LedgerVault API", version="2.0.0")
models.Base.metadata.create_all(bind=engine)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


@app.get("/")
def root():
    return {"status": "ok", "message": "LedgerVault v2 backend is running"}


# -----------------------------------
# Accounts
# -----------------------------------

@app.get("/accounts", response_model=AccountList)
def list_accounts(db: Session = Depends(get_db)):
    items = db.query(models.Account).all()
    return {"items": items}


@app.post("/accounts", response_model=AccountOut)
def create_account(payload: AccountCreate, db: Session = Depends(get_db)):
    new_item = models.Account(
        id=str(uuid4()),
        name=payload.name,
        account_type=payload.account_type,
        base_currency=payload.base_currency.upper(),
    )
    db.add(new_item)
    db.commit()
    db.refresh(new_item)
    return new_item


@app.put("/accounts/{account_id}", response_model=AccountOut)
def update_account(account_id: str, payload: AccountUpdate, db: Session = Depends(get_db)):
    item = db.query(models.Account).filter(models.Account.id == account_id).first()
    if not item:
        raise HTTPException(status_code=404, detail="Account not found")

    if payload.name is not None:
        item.name = payload.name
    if payload.account_type is not None:
        item.account_type = payload.account_type
    if payload.base_currency is not None:
        item.base_currency = payload.base_currency.upper()

    db.commit()
    db.refresh(item)
    return item


@app.delete("/accounts/{account_id}")
def delete_account(account_id: str, db: Session = Depends(get_db)):
    item = db.query(models.Account).filter(models.Account.id == account_id).first()
    if not item:
        raise HTTPException(status_code=404, detail="Account not found")

    db.delete(item)
    db.commit()
    return {"status": "ok"}


# -----------------------------------
# Assets
# -----------------------------------

@app.get("/assets", response_model=AssetList)
def list_assets(db: Session = Depends(get_db)):
    items = db.query(models.Asset).all()
    return {"items": items}


@app.post("/assets", response_model=AssetOut)
def create_asset(payload: AssetCreate, db: Session = Depends(get_db)):
    existing = db.query(models.Asset).filter(models.Asset.symbol == payload.symbol.upper()).first()
    if existing:
        return existing

    new_item = models.Asset(
        id=str(uuid4()),
        symbol=payload.symbol.upper(),
        name=payload.name,
        asset_class=payload.asset_class,
        quote_currency=payload.quote_currency.upper(),
    )
    db.add(new_item)
    db.commit()
    db.refresh(new_item)
    return new_item


# -----------------------------------
# Holdings
# -----------------------------------

@app.get("/holdings", response_model=HoldingList)
def list_holdings(db: Session = Depends(get_db)):
    items = db.query(models.Holding).all()
    return {"items": items}


# -----------------------------------
# Transactions
# -----------------------------------

@app.get("/transactions", response_model=TransactionList)
def list_transactions(db: Session = Depends(get_db)):
    items = db.query(models.Transaction).all()
    return {"items": items}


@app.post("/transactions", response_model=TransactionOut)
def create_transaction(payload: TransactionCreate, db: Session = Depends(get_db)):
    account = db.query(models.Account).filter(models.Account.id == payload.account_id).first()
    if not account:
        raise HTTPException(status_code=404, detail="Account not found")

    asset = db.query(models.Asset).filter(models.Asset.id == payload.asset_id).first()
    if not asset:
        raise HTTPException(status_code=404, detail="Asset not found")

    holding = (
        db.query(models.Holding)
        .filter(
            models.Holding.account_id == payload.account_id,
            models.Holding.asset_id == payload.asset_id
        )
        .first()
    )

    if not holding:
        holding = models.Holding(
            id=str(uuid4()),
            account_id=payload.account_id,
            asset_id=payload.asset_id,
            quantity=0.0,
            avg_cost=0.0,
        )
        db.add(holding)
        db.flush()

    # Simple MVP holding logic
    if payload.type in ["deposit", "buy", "transfer_in"]:
        new_total_qty = holding.quantity + payload.quantity

        if payload.price is not None and payload.quantity > 0:
            existing_cost_value = holding.quantity * holding.avg_cost
            new_cost_value = payload.quantity * payload.price
            if new_total_qty > 0:
                holding.avg_cost = (existing_cost_value + new_cost_value) / new_total_qty

        holding.quantity = new_total_qty

    elif payload.type in ["withdrawal", "sell", "transfer_out"]:
        holding.quantity -= payload.quantity
        if holding.quantity < 0:
            holding.quantity = 0

    new_item = models.Transaction(
        id=str(uuid4()),
        account_id=payload.account_id,
        asset_id=payload.asset_id,
        type=payload.type,
        quantity=payload.quantity,
        price=payload.price,
        fee=payload.fee,
        fee_currency=payload.fee_currency.upper() if payload.fee_currency else None,
        total_value=payload.total_value,
        note=payload.note,
    )

    db.add(new_item)
    db.commit()
    db.refresh(new_item)
    return new_item


# -----------------------------------
# Seed endpoint for fast testing
# -----------------------------------

@app.post("/seed")
def seed_data(db: Session = Depends(get_db)):
    if not db.query(models.Asset).filter(models.Asset.symbol == "EUR").first():
        db.add(models.Asset(
            id=str(uuid4()),
            symbol="EUR",
            name="Euro",
            asset_class="fiat",
            quote_currency="EUR",
        ))

    if not db.query(models.Asset).filter(models.Asset.symbol == "USD").first():
        db.add(models.Asset(
            id=str(uuid4()),
            symbol="USD",
            name="US Dollar",
            asset_class="fiat",
            quote_currency="USD",
        ))

    if not db.query(models.Asset).filter(models.Asset.symbol == "BTC").first():
        db.add(models.Asset(
            id=str(uuid4()),
            symbol="BTC",
            name="Bitcoin",
            asset_class="crypto",
            quote_currency="USD",
        ))

    if not db.query(models.Asset).filter(models.Asset.symbol == "ETH").first():
        db.add(models.Asset(
            id=str(uuid4()),
            symbol="ETH",
            name="Ethereum",
            asset_class="crypto",
            quote_currency="USD",
        ))

    db.commit()
    return {"status": "ok"}
