import uuid

from fastapi import APIRouter, Depends, Query
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import require_manager
from app.db.session import get_db
from app.models.enums import AuthorizationStatus, VehicleStatus, VehicleType
from app.models.user import User
from app.schemas.common import Page
from app.schemas.emergency import (
    ApproveRequest,
    AuthorizationReviewOut,
    EmergencyEventOut,
    EndEmergencyRequest,
    ReviewNotesRequest,
)
from app.schemas.telemetry import LiveVehicleOut, TelemetryPointOut
from app.schemas.vehicle import ManagerVehicleOut, VehicleStatusUpdate
from app.services import emergency_service, live_service, vehicle_service

router = APIRouter(prefix="/manager", tags=["manager"])


@router.get("/vehicles", response_model=Page[ManagerVehicleOut])
async def list_vehicles(
    vehicle_type: VehicleType | None = Query(default=None, alias="vehicleType"),
    status: VehicleStatus | None = None,
    simulated: bool | None = None,
    limit: int = Query(default=50, ge=1, le=200),
    offset: int = Query(default=0, ge=0),
    _: User = Depends(require_manager),
    db: AsyncSession = Depends(get_db),
) -> Page[ManagerVehicleOut]:
    return await vehicle_service.list_manager_vehicles(
        db, vehicle_type=vehicle_type, status=status, is_simulated=simulated, limit=limit, offset=offset
    )


@router.get("/vehicles/{vehicle_id}", response_model=ManagerVehicleOut)
async def get_vehicle(
    vehicle_id: uuid.UUID, _: User = Depends(require_manager), db: AsyncSession = Depends(get_db)
) -> ManagerVehicleOut:
    return await vehicle_service.get_manager_vehicle(db, vehicle_id)


@router.patch("/vehicles/{vehicle_id}/status", response_model=ManagerVehicleOut)
async def set_vehicle_status(
    vehicle_id: uuid.UUID,
    body: VehicleStatusUpdate,
    user: User = Depends(require_manager),
    db: AsyncSession = Depends(get_db),
) -> ManagerVehicleOut:
    return await vehicle_service.set_vehicle_status(db, user, vehicle_id, body.status, body.reason)


# -- live monitoring -------------------------------------------------------------------

@router.get("/live/vehicles", response_model=list[LiveVehicleOut])
async def live_vehicles(
    include_simulated: bool = Query(default=True, alias="includeSimulated"),
    only_active: bool = Query(default=True, alias="onlyActive"),
    _: User = Depends(require_manager),
    db: AsyncSession = Depends(get_db),
) -> list[LiveVehicleOut]:
    return await live_service.live_vehicles(db, include_simulated=include_simulated, only_active=only_active)


@router.get("/live/vehicles/{vehicle_id}", response_model=LiveVehicleOut)
async def live_vehicle(
    vehicle_id: uuid.UUID, _: User = Depends(require_manager), db: AsyncSession = Depends(get_db)
) -> LiveVehicleOut:
    return await live_service.live_vehicle(db, vehicle_id)


@router.get("/vehicles/{vehicle_id}/telemetry", response_model=list[TelemetryPointOut])
async def vehicle_track(
    vehicle_id: uuid.UUID,
    minutes: int = Query(default=10, ge=1, le=24 * 60),
    limit: int = Query(default=600, ge=1, le=5000),
    _: User = Depends(require_manager),
    db: AsyncSession = Depends(get_db),
) -> list[TelemetryPointOut]:
    return await live_service.vehicle_track(db, vehicle_id, minutes, limit)


# -- emergency vehicles ----------------------------------------------------------------

@router.get("/emergency/authorizations", response_model=list[AuthorizationReviewOut])
async def list_authorizations(
    status: AuthorizationStatus | None = None,
    include_simulated: bool = Query(default=False, alias="includeSimulated"),
    _: User = Depends(require_manager),
    db: AsyncSession = Depends(get_db),
) -> list[AuthorizationReviewOut]:
    return await emergency_service.list_authorizations(db, status, include_simulated)


@router.post("/emergency/authorizations/{authorization_id}/approve", response_model=AuthorizationReviewOut)
async def approve_authorization(
    authorization_id: uuid.UUID, body: ApproveRequest,
    user: User = Depends(require_manager), db: AsyncSession = Depends(get_db),
) -> AuthorizationReviewOut:
    return await emergency_service.approve(db, user, authorization_id, body.valid_until, body.notes)


@router.post("/emergency/authorizations/{authorization_id}/reject", response_model=AuthorizationReviewOut)
async def reject_authorization(
    authorization_id: uuid.UUID, body: ReviewNotesRequest,
    user: User = Depends(require_manager), db: AsyncSession = Depends(get_db),
) -> AuthorizationReviewOut:
    return await emergency_service.reject(db, user, authorization_id, body.notes)


@router.post("/vehicles/{vehicle_id}/emergency-authorization/revoke", response_model=AuthorizationReviewOut)
async def revoke_authorization(
    vehicle_id: uuid.UUID, body: ReviewNotesRequest,
    user: User = Depends(require_manager), db: AsyncSession = Depends(get_db),
) -> AuthorizationReviewOut:
    return await emergency_service.revoke(db, user, vehicle_id, body.notes)


@router.get("/emergency/events", response_model=list[EmergencyEventOut])
async def emergency_events(
    limit: int = Query(default=50, ge=1, le=500),
    include_simulated: bool = Query(default=True, alias="includeSimulated"),
    _: User = Depends(require_manager),
    db: AsyncSession = Depends(get_db),
) -> list[EmergencyEventOut]:
    return await emergency_service.list_events(db, limit, include_simulated)


@router.post("/emergency/events/{event_id}/end", response_model=EmergencyEventOut)
async def end_emergency(
    event_id: uuid.UUID, body: EndEmergencyRequest,
    user: User = Depends(require_manager), db: AsyncSession = Depends(get_db),
) -> EmergencyEventOut:
    return await emergency_service.manager_end(db, user, event_id, body.note)
