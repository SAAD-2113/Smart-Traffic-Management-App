from fastapi import APIRouter, Depends
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.time import utcnow
from app.db.session import get_db

router = APIRouter(tags=["system"])


@router.get("/health")
async def health(db: AsyncSession = Depends(get_db)) -> dict:
    try:
        await db.execute(text("SELECT 1"))
        database = "ok"
    except Exception:
        database = "unavailable"
    return {"status": "ok" if database == "ok" else "degraded", "database": database, "serverTime": utcnow()}
