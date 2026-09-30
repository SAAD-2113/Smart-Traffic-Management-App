import uuid

from fastapi import APIRouter, Depends, Query
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import require_manager
from app.db.session import get_db
from app.models.enums import VehicleStatus, VehicleType
from app.models.user import User
from app.schemas.common import Page
from app.schemas.vehicle import ManagerVehicleOut, VehicleStatusUpdate
from app.services import vehicle_service

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
