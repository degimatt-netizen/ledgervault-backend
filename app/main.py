from uuid import uuid4

from fastapi import FastAPI, Depends, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy.orm import Session

from app.db import engine, SessionLocal, Base
from app import models
from app.schemas import (
    AccountList, AccountOut, AccountCreate, AccountUpdate,
    AssetList, AssetOut, AssetCreate,
    HoldingList, HoldingOut,
    TransactionEventList, TransactionEventOut, TransactionEventCreate,
    TransactionLegList
)

app = FastAPI(title="LedgerVault API", version="3.0.0")
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
    return {"status": "ok", "message": "LedgerVault v3 backend is running"}


@app.post("/reset")
def reset_database():
    Base.metadata.drop_all(bind=engine)
    Base.metadata.create_all(bind=engine)
    return {"status": "ok", "message": "database reset complete"}


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
# Transaction Events v3
# -----------------------------------

@app.get("/transaction-events", response_model=TransactionEventList)
def list_transaction_events(db: Session = Depends(get_db)):
    items = db.query(models.TransactionEvent).all()
    return {"items": items}


@app.get("/transaction-legs", response_model=TransactionLegList)
def list_transaction_legs(db: Session = Depends(get_db)):
    items = db.query(models.TransactionLeg).all()
    return {"items": items}


@app.post("/transaction-events", response_model=TransactionEventOut)
def create_transaction_event(payload: TransactionEventCreate, db: Session = Depends(get_db)):
    if len(payload.legs) == 0:
        raise HTTPException(status_code=400, detail="At least one leg is required")

    new_event = models.TransactionEvent(
        id=str(uuid4()),
        event_type=payload.event_type,
        category=payload.category,
        description=payload.description,
        date=payload.date,
        note=payload.note,
        source=payload.source,
        external_id=payload.external_id,
    )
    db.add(new_event)
    db.flush()

    for leg in payload.legs:
        account = db.query(models.Account).filter(models.Account.id == leg.account_id).first()
        if not account:
            raise HTTPException(status_code=404, detail=f"Account not found: {leg.account_id}")

        asset = db.query(models.Asset).filter(models.Asset.id == leg.asset_id).first()
        if not asset:
            raise HTTPException(status_code=404, detail=f"Asset not found: {leg.asset_id}")

        holding = (
            db.query(models.Holding)
            .filter(
                models.Holding.account_id == leg.account_id,
                models.Holding.asset_id == leg.asset_id
            )
            .first()
        )

        if not holding:
            holding = models.Holding(
                id=str(uuid4()),
                account_id=leg.account_id,
                asset_id=leg.asset_id,
                quantity=0.0,
                avg_cost=0.0,
            )
            db.add(holding)
            db.flush()

        # Update holdings
        old_qty = holding.quantity
        new_qty = old_qty + leg.quantity

        if leg.quantity > 0 and leg.unit_price is not None:
            existing_cost_value = old_qty * holding.avg_cost
            new_cost_value = leg.quantity * leg.unit_price
            if new_qty > 0:
                holding.avg_cost = (existing_cost_value + new_cost_value) / new_qty

        holding.quantity = max(new_qty, 0.0)

        new_leg = models.TransactionLeg(
            id=str(uuid4()),
            event_id=new_event.id,
            account_id=leg.account_id,
            asset_id=leg.asset_id,
            quantity=leg.quantity,
            unit_price=leg.unit_price,
            fee_flag="true" if leg.fee_flag else "false",
        )
        db.add(new_leg)

    db.commit()
    db.refresh(new_event)
    return new_event


# -----------------------------------
# Seed endpoint
# -----------------------------------

@app.post("/seed")
def seed_data(db: Session = Depends(get_db)):
    seed_assets = [
        ("EUR", "Euro", "fiat", "EUR"),
        ("USD", "US Dollar", "fiat", "USD"),
        ("USDT", "Tether", "crypto", "USD"),
        ("USDC", "USD Coin", "crypto", "USD"),
        ("BTC", "Bitcoin", "crypto", "USD"),
        ("ETH", "Ethereum", "crypto", "USD"),
    ]

    for symbol, name, asset_class, quote_currency in seed_assets:
        existing = db.query(models.Asset).filter(models.Asset.symbol == symbol).first()
        if not existing:
            db.add(models.Asset(
                id=str(uuid4()),
                symbol=symbol,
                name=name,
                asset_class=asset_class,
                quote_currency=quote_currency,
            ))

    db.commit()
    return {"status": "ok"}