"""Traffic state for managers: overview, per-intersection metrics, history, emergencies."""
import uuid

from fastapi import APIRouter, Depends, Query
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.api.deps import require_manager
from app.core.errors import not_found
from app.core.time import utcnow
from app.db.session import get_db, get_session_factory
from app.models.user import User
from app.schemas.emergency import ActiveEmergencyOut
from app.schemas.traffic import IntersectionHistoryOut, IntersectionTrafficOut, NetworkHistoryOut, OverviewOut
from app.services import emergency_service, live_service, traffic_history

router = APIRouter(tags=["traffic"])


@router.get("/traffic/overview", response_model=OverviewOut)
async def overview(
    _: User = Depends(require_manager),
    db: AsyncSession = Depends(get_db),
    factory: async_sessionmaker = Depends(get_session_factory),
) -> OverviewOut:
    snapshot = await live_service.current_snapshot(factory)
    return await live_service.overview(db, snapshot, utcnow())


@router.get("/traffic/intersections", response_model=list[IntersectionTrafficOut])
async def intersections(
    _: User = Depends(require_manager),
    db: AsyncSession = Depends(get_db),
    factory: async_sessionmaker = Depends(get_session_factory),
) -> list[IntersectionTrafficOut]:
    snapshot = await live_service.current_snapshot(factory)
    return await live_service.intersections_traffic(db, snapshot, utcnow())


@router.get("/traffic/intersections/{intersection_id}", response_model=IntersectionTrafficOut)
async def intersection(
    intersection_id: uuid.UUID,
    _: User = Depends(require_manager),
    db: AsyncSession = Depends(get_db),
    factory: async_sessionmaker = Depends(get_session_factory),
) -> IntersectionTrafficOut:
    snapshot = await live_service.current_snapshot(factory)
    for item in await live_service.intersections_traffic(db, snapshot, utcnow()):
        if item.id == intersection_id:
            return item
    raise not_found("Intersection")


@router.get("/traffic/intersections/{intersection_id}/history", response_model=IntersectionHistoryOut)
async def intersection_history(
    intersection_id: uuid.UUID,
    hours: float = Query(default=1.0, gt=0, le=24 * 7),
    bucket_s: int = Query(default=60, ge=30, le=3600, alias="bucketS"),
    _: User = Depends(require_manager),
    db: AsyncSession = Depends(get_db),
) -> IntersectionHistoryOut:
    return await traffic_history.intersection_history(db, intersection_id, hours, bucket_s)


@router.get("/traffic/history", response_model=NetworkHistoryOut)
async def network_history(
    hours: float = Query(default=1.0, gt=0, le=24 * 7),
    bucket_s: int = Query(default=60, ge=30, le=3600, alias="bucketS"),
    _: User = Depends(require_manager),
    db: AsyncSession = Depends(get_db),
) -> NetworkHistoryOut:
    return await traffic_history.network_history(db, hours, bucket_s)


@router.get("/emergency/active", response_model=list[ActiveEmergencyOut])
async def active_emergencies(
    include_simulated: bool = Query(default=True, alias="includeSimulated"),
    _: User = Depends(require_manager),
    db: AsyncSession = Depends(get_db),
) -> list[ActiveEmergencyOut]:
    return await emergency_service.list_active(db, include_simulated)
