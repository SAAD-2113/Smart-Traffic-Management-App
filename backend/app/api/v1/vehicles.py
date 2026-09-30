import uuid

from fastapi import APIRouter, Depends, status
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import require_end_user
from app.db.session import get_db
from app.models.user import User
from app.models.vehicle import Device
from app.schemas.vehicle import DeviceBindRequest, DeviceOut, OwnerVehicleOut, VehicleCreate
from app.services import vehicle_service

router = APIRouter(prefix="/vehicles", tags=["vehicles (owner)"])


@router.post("", response_model=OwnerVehicleOut, status_code=status.HTTP_201_CREATED)
async def register_vehicle(
    body: VehicleCreate, user: User = Depends(require_end_user), db: AsyncSession = Depends(get_db)
) -> OwnerVehicleOut:
    return await vehicle_service.register_vehicle(db, user, body)


@router.get("/{vehicle_id}", response_model=OwnerVehicleOut)
async def get_vehicle(
    vehicle_id: uuid.UUID, user: User = Depends(require_end_user), db: AsyncSession = Depends(get_db)
) -> OwnerVehicleOut:
    return await vehicle_service.get_owner_vehicle(db, user, vehicle_id)


@router.post("/{vehicle_id}/devices", response_model=DeviceOut)
async def bind_device(
    vehicle_id: uuid.UUID,
    body: DeviceBindRequest,
    user: User = Depends(require_end_user),
    db: AsyncSession = Depends(get_db),
) -> Device:
    return await vehicle_service.bind_device(db, user, vehicle_id, body)


@router.get("/{vehicle_id}/devices", response_model=list[DeviceOut])
async def list_devices(
    vehicle_id: uuid.UUID, user: User = Depends(require_end_user), db: AsyncSession = Depends(get_db)
) -> list[Device]:
    return await vehicle_service.list_devices(db, user, vehicle_id)


@router.delete("/{vehicle_id}/devices/{device_id}", status_code=status.HTTP_204_NO_CONTENT)
async def unbind_device(
    vehicle_id: uuid.UUID,
    device_id: uuid.UUID,
    user: User = Depends(require_end_user),
    db: AsyncSession = Depends(get_db),
) -> None:
    await vehicle_service.unbind_device(db, user, vehicle_id, device_id)
