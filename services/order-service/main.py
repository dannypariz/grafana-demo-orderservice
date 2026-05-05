import os
import logging

from telemetry import setup_telemetry

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

setup_telemetry("order-service")

from fastapi import FastAPI, HTTPException
import httpx

app = FastAPI(title="order-service")

BUG_ENABLED = os.getenv("BUG_ENABLED", "false").lower() == "true"
INVENTORY_URL = os.getenv("INVENTORY_SERVICE_URL", "http://inventory-service:8080")

ORDERS = {
    "order-1": {"id": "order-1", "customer": "Alice",   "item_ids": ["item-1", "item-2", "item-3"]},
    "order-2": {"id": "order-2", "customer": "Bob",     "item_ids": ["item-2", "item-4", "item-5"]},
    "order-3": {"id": "order-3", "customer": "Charlie", "item_ids": ["item-1", "item-3", "item-4", "item-5"]},
    "order-4": {"id": "order-4", "customer": "Diana",   "item_ids": ["item-1", "item-2", "item-3", "item-4", "item-5"]},
    "order-5": {"id": "order-5", "customer": "Eve",     "item_ids": ["item-3", "item-5"]},
    "order-6": {"id": "order-6", "customer": "Frank",   "item_ids": ["item-1", "item-2", "item-3", "item-4", "item-5", "item-6", "item-7", "item-8", "item-9", "item-10"]},
}


@app.get("/health")
async def health():
    return {"status": "ok", "service": "order-service", "bug_enabled": BUG_ENABLED}


@app.get("/orders/{order_id}")
async def get_order(order_id: str):
    logger.info("get_order order_id=%s bug_enabled=%s", order_id, BUG_ENABLED)
    order = ORDERS.get(order_id)
    if not order:
        raise HTTPException(status_code=404, detail=f"Order {order_id} not found")

    items = []
    if BUG_ENABLED:
        # N+1 bug: one HTTP call per item, each ~80ms → N×80ms total latency
        async with httpx.AsyncClient() as client:
            for item_id in order["item_ids"]:
                r = await client.get(f"{INVENTORY_URL}/items/{item_id}", timeout=10.0)
                items.append(r.json())
    else:
        # Fix: single batch call — ~80ms regardless of item count
        ids = ",".join(order["item_ids"])
        async with httpx.AsyncClient() as client:
            r = await client.get(f"{INVENTORY_URL}/items/batch?ids={ids}", timeout=10.0)
            items = r.json()

    return {"order": order, "items": items}
