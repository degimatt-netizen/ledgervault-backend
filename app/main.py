from uuid import uuid4

from fastapi import FastAPI, Depends, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy.orm import Session

from app.db import engine, SessionLocal, Base
from app import models
from app.schemas import (
    AccountList, AccountOut, AccountCreate, AccountUpdate,
    AssetList, AssetOut, AssetCreate,
    HoldingList,
    TransactionEventList, TransactionEventOut, TransactionEventCreate,
    TransactionLegList
)

app = FastAPI(title="LedgerVault API", version="3.1.1")
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
    return {"status": "ok", "message": "LedgerVault personal MVP backend is running"}


@app.post("/reset")
def reset_database():
    Base.metadata.drop_all(bind=engine)
    Base.metadata.create_all(bind=engine)
    return {"status": "ok", "message": "database reset complete"}


MOCK_PRICES_USD = {
    "USD": 1.0,
    "EUR": 1.08,
    "GBP": 1.27,
    "USDT": 1.0,
    "USDC": 1.0,
    "BTC": 90000.0,
    "ETH": 3500.0,
    "TSLA": 10.0,
    "AAPL": 210.0,
}

FX_TO_USD = {
    "USD": 1.0,
    "EUR": 1.08,
    "GBP": 1.27,
}


def convert_usd_to_base(value_usd: float, base_currency: str) -> float:
    rate = FX_TO_USD.get(base_currency.upper(), 1.0)
    return value_usd / rate if rate != 0 else value_usd


@app.get("/rates")
def get_rates():
    return {
        "base_reference": "USD",
        "prices": MOCK_PRICES_USD,
        "fx_to_usd": FX_TO_USD
    }


@app.get("/valuation")
def valuation(base_currency: str = "EUR", db: Session = Depends(get_db)):
    holdings = db.query(models.Holding).all()
    assets = {a.id: a for a in db.query(models.Asset).all()}
    accounts = {a.id: a for a in db.query(models.Account).all()}

    portfolio_items = []
    total_value_base = 0.0
    cash_total = 0.0
    crypto_total = 0.0
    stock_total = 0.0

    for holding in holdings:
        asset = assets.get(holding.asset_id)
        account = accounts.get(holding.account_id)
        if not asset or not account:
            continue

        price_usd = MOCK_PRICES_USD.get(asset.symbol.upper(), 0.0)
        value_usd = holding.quantity * price_usd
        value_base = convert_usd_to_base(value_usd, base_currency)

        portfolio_items.append({
            "holding_id": holding.id,
            "account_id": account.id,
            "account_name": account.name,
            "asset_id": asset.id,
            "symbol": asset.symbol,
            "asset_name": asset.name,
            "asset_class": asset.asset_class,
            "quantity": holding.quantity,
            "avg_cost": holding.avg_cost,
            "price_usd": price_usd,
            "value_in_base": round(value_base, 2),
            "base_currency": base_currency.upper(),
        })

        total_value_base += value_base

        if asset.asset_class == "fiat":
            cash_total += value_base
        elif asset.asset_class == "crypto":
            crypto_total += value_base
        elif asset.asset_class in ["stock", "etf"]:
            stock_total += value_base

    recent_events = (
        db.query(models.TransactionEvent)
        .order_by(models.TransactionEvent.date.desc())
        .all()[:10]
    )

    return {
        "base_currency": base_currency.upper(),
        "total": round(total_value_base, 2),
        "cash": round(cash_total, 2),
        "crypto": round(crypto_total, 2),
        "stocks": round(stock_total, 2),
        "portfolio": portfolio_items,
        "recent_activity": [
            {
                "id": e.id,
                "event_type": e.event_type,
                "category": e.category,
                "description": e.description,
                "date": e.date,
                "note": e.note,
            }
            for e in recent_events
        ]
    }


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

    has_legs = (
        db.query(models.TransactionLeg)
        .filter(models.TransactionLeg.account_id == account_id)
        .first()
        is not None
    )

    has_holdings = (
        db.query(models.Holding)
        .filter(models.Holding.account_id == account_id)
        .first()
        is not None
    )

    if has_legs or has_holdings:
        raise HTTPException(
            status_code=400,
            detail="Cannot delete account with activity or holdings. Delete related transactions first."
        )

    db.delete(item)
    db.commit()
    return {"status": "ok"}


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


@app.get("/holdings", response_model=HoldingList)
def list_holdings(db: Session = Depends(get_db)):
    items = db.query(models.Holding).all()
    return {"items": items}


@app.get("/transaction-events", response_model=TransactionEventList)
def list_transaction_events(db: Session = Depends(get_db)):
    items = (
        db.query(models.TransactionEvent)
        .order_by(models.TransactionEvent.date.desc())
        .all()
    )
    return {"items": items}


@app.get("/transaction-legs", response_model=TransactionLegList)
def list_transaction_legs(db: Session = Depends(get_db)):
    items = db.query(models.TransactionLeg).all()
    return {"items": items}


@app.delete("/transaction-events/{event_id}")
def delete_transaction_event(event_id: str, db: Session = Depends(get_db)):
    event = db.query(models.TransactionEvent).filter(models.TransactionEvent.id == event_id).first()
    if not event:
        raise HTTPException(status_code=404, detail="Transaction event not found")

    legs = db.query(models.TransactionLeg).filter(models.TransactionLeg.event_id == event_id).all()

    for leg in legs:
        holding = (
            db.query(models.Holding)
            .filter(
                models.Holding.account_id == leg.account_id,
                models.Holding.asset_id == leg.asset_id
            )
            .first()
        )

        if holding:
            holding.quantity -= leg.quantity
            if holding.quantity <= 0:
                db.delete(holding)

        db.delete(leg)

    db.delete(event)
    db.commit()
    return {"status": "ok"}


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

        old_qty = holding.quantity
        new_qty = old_qty + leg.quantity

        if leg.quantity > 0 and leg.unit_price is not None:
            existing_cost_value = old_qty * holding.avg_cost
            new_cost_value = leg.quantity * leg.unit_price
            if new_qty > 0:
                holding.avg_cost = (existing_cost_value + new_cost_value) / new_qty

        holding.quantity = max(new_qty, 0.0)

        if holding.quantity == 0:
            db.delete(holding)

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


@app.post("/seed")
def seed_data(db: Session = Depends(get_db)):
    seed_assets = [
        ("EUR", "Euro", "fiat", "EUR"),
        ("USD", "US Dollar", "fiat", "USD"),
        ("GBP", "British Pound", "fiat", "GBP"),
        ("USDT", "Tether", "crypto", "USD"),
        ("USDC", "USD Coin", "crypto", "USD"),
        ("BTC", "Bitcoin", "crypto", "USD"),
        ("ETH", "Ethereum", "crypto", "USD"),
        ("TSLA", "Tesla", "stock", "USD"),
        ("AAPL", "Apple", "stock", "USD"),
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