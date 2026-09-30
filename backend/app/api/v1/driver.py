"""Driver (vehicle owner) endpoints: tracking, telemetry, trips and emergency mode."""
import uuid

from fastapi import APIRouter, Depends, Header, Query, Request, status
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import require_end_user
from app.core.rate_limit import limiter
from app.db.session import get_db
from app.models.user import User
from app.schemas.emergency import EmergencyEventOut, EmergencyStartRequest, EmergencyStatusOut
from app.schemas.telemetry import (
    OwnerLatestOut,
    TelemetryBatch,
    TelemetryBatchResult,
    TrackingSessionOut,
    TrackingStartRequest,
    TrackingStopRequest,
)
from app.services import emergency_service, live_service, telemetry_service, tracking_service

router = APIRouter(prefix="/vehicles", tags=["driver: tracking, telemetry, emergency"])

InstallationId = Header(default=None, alias="X-Installation-Id", pattern=r"^[A-Za-z0-9-]{8,64}$")


@router.post("/{vehicle_id}/tracking/start", response_model=TrackingSessionOut, status_code=status.HTTP_201_CREATED)
async def start_tracking(
    vehicle_id: uuid.UUID,
    body: TrackingStartRequest | None = None,
    installation_id: str | None = InstallationId,
    user: User = Depends(require_end_user),
    db: AsyncSession = Depends(get_db),
) -> TrackingSessionOut:
    session = await tracking_service.start(db, user, vehicle_id, installation_id)
    return tracking_service.to_out(session)


@router.post("/{vehicle_id}/tracking/stop", response_model=TrackingSessionOut | None)
async def stop_tracking(
    vehicle_id: uuid.UUID,
    body: TrackingStopRequest | None = None,
    user: User = Depends(require_end_user),
    db: AsyncSession = Depends(get_db),
) -> TrackingSessionOut | None:
    session = await tracking_service.stop(db, user, vehicle_id, body.session_id if body else None)
    return tracking_service.to_out(session) if session else None


@router.get("/{vehicle_id}/tracking/sessions", response_model=list[TrackingSessionOut])
async def list_sessions(
    vehicle_id: uuid.UUID,
    limit: int = Query(default=20, ge=1, le=100),
    user: User = Depends(require_end_user),
    db: AsyncSession = Depends(get_db),
) -> list[TrackingSessionOut]:
    return await tracking_service.list_sessions(db, user, vehicle_id, limit)


@router.post("/{vehicle_id}/telemetry", response_model=TelemetryBatchResult)
@limiter.limit("240/minute")
async def post_telemetry(
    request: Request,
    vehicle_id: uuid.UUID,
    body: TelemetryBatch,
    installation_id: str | None = InstallationId,
    user: User = Depends(require_end_user),
    db: AsyncSession = Depends(get_db),
) -> TelemetryBatchResult:
    return await telemetry_service.ingest_mobile(db, user, vehicle_id, installation_id, body)


@router.get("/{vehicle_id}/telemetry/latest", response_model=OwnerLatestOut)
async def latest_telemetry(
    vehicle_id: uuid.UUID, user: User = Depends(require_end_user), db: AsyncSession = Depends(get_db)
) -> OwnerLatestOut:
    return await live_service.owner_latest(db, user, vehicle_id)


@router.get("/{vehicle_id}/emergency", response_model=EmergencyStatusOut)
async def emergency_status(
    vehicle_id: uuid.UUID, user: User = Depends(require_end_user), db: AsyncSession = Depends(get_db)
) -> EmergencyStatusOut:
    return await emergency_service.status_for_owner(db, user, vehicle_id)


@router.post("/{vehicle_id}/emergency/start", response_model=EmergencyEventOut)
@limiter.limit("10/minute")
async def start_emergency(
    request: Request,
    vehicle_id: uuid.UUID,
    body: EmergencyStartRequest,
    installation_id: str | None = InstallationId,
    user: User = Depends(require_end_user),
    db: AsyncSession = Depends(get_db),
) -> EmergencyEventOut:
    return await emergency_service.start(db, user, vehicle_id, installation_id, body.confirm)


@router.post("/{vehicle_id}/emergency/stop", response_model=EmergencyEventOut | None)
async def stop_emergency(
    vehicle_id: uuid.UUID, user: User = Depends(require_end_user), db: AsyncSession = Depends(get_db)
) -> EmergencyEventOut | None:
    return await emergency_service.stop(db, user, vehicle_id)


@router.post("/{vehicle_id}/emergency/authorization-request", response_model=EmergencyStatusOut)
@limiter.limit("5/hour")
async def request_authorization(
    request: Request, vehicle_id: uuid.UUID, user: User = Depends(require_end_user), db: AsyncSession = Depends(get_db)
) -> EmergencyStatusOut:
    return await emergency_service.request_authorization(db, user, vehicle_id)
