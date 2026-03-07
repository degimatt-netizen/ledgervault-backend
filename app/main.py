from uuid import uuid4

from fastapi import FastAPI, Depends, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy.orm import Session

from app.db import engine, SessionLocal
from app import models
from app.schemas import (
    WalletList, WalletOut, WalletCreate, WalletUpdate,
    TransactionList, TransactionOut, TransactionCreate
)

app = FastAPI(title="LedgerVault API", version="0.1.0")
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
    return {"status": "ok", "message": "LedgerVault backend is running"}


# ------------------------
# Wallets
# ------------------------

@app.get("/wallets", response_model=WalletList)
def list_wallets(db: Session = Depends(get_db)):
    items = db.query(models.Wallet).all()
    return {"items": items}


@app.post("/wallets", response_model=WalletOut)
def create_wallet(payload: WalletCreate, db: Session = Depends(get_db)):
    new_wallet = models.Wallet(
        id=str(uuid4()),
        name=payload.name,
        kind=payload.kind,
        currency=payload.currency.upper(),
        balance=payload.balance,
    )
    db.add(new_wallet)
    db.commit()
    db.refresh(new_wallet)
    return new_wallet


@app.put("/wallets/{wallet_id}", response_model=WalletOut)
def update_wallet(wallet_id: str, payload: WalletUpdate, db: Session = Depends(get_db)):
    wallet = db.query(models.Wallet).filter(models.Wallet.id == wallet_id).first()
    if not wallet:
        raise HTTPException(status_code=404, detail="Wallet not found")

    if payload.name is not None:
        wallet.name = payload.name
    if payload.kind is not None:
        wallet.kind = payload.kind
    if payload.currency is not None:
        wallet.currency = payload.currency.upper()
    if payload.balance is not None:
        wallet.balance = payload.balance

    db.commit()
    db.refresh(wallet)
    return wallet


@app.delete("/wallets/{wallet_id}")
def delete_wallet(wallet_id: str, db: Session = Depends(get_db)):
    wallet = db.query(models.Wallet).filter(models.Wallet.id == wallet_id).first()
    if not wallet:
        raise HTTPException(status_code=404, detail="Wallet not found")

    db.delete(wallet)
    db.commit()
    return {"status": "ok"}


# ------------------------
# Transactions
# ------------------------

@app.get("/transactions", response_model=TransactionList)
def list_transactions(db: Session = Depends(get_db)):
    items = db.query(models.Transaction).all()
    return {"items": items}


@app.post("/transactions", response_model=TransactionOut)
def create_transaction(payload: TransactionCreate, db: Session = Depends(get_db)):
    wallet = db.query(models.Wallet).filter(models.Wallet.id == payload.wallet_id).first()
    if not wallet:
        raise HTTPException(status_code=404, detail="Wallet not found")

    new_tx = models.Transaction(
        id=str(uuid4()),
        wallet_id=payload.wallet_id,
        type=payload.type,
        asset=payload.asset,
        amount=payload.amount,
        price_per_unit=payload.price_per_unit,
        total_value=payload.total_value,
        currency=payload.currency.upper(),
        note=payload.note,
    )

    # update wallet balance for simple MVP logic
    if payload.type in ["deposit", "transfer_in", "sell"]:
        wallet.balance += payload.total_value
    elif payload.type in ["withdraw", "transfer_out", "buy"]:
        wallet.balance -= payload.total_value

    db.add(new_tx)
    db.commit()
    db.refresh(new_tx)
    return new_tx

@app.get("/networth")
def networth(db: Session = Depends(get_db)):

    wallets = db.query(models.Wallet).all()

    total = 0

    fiat_total = 0
    crypto_total = 0

    for wallet in wallets:

        total += wallet.balance

        if wallet.kind == "fiat":
            fiat_total += wallet.balance
        else:
            crypto_total += wallet.balance

    return {
        "total": total,
        "fiat": fiat_total,
        "crypto": crypto_total
    }
