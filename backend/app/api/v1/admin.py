import uuid

from fastapi import APIRouter, Depends, status
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import require_admin
from app.db.session import get_db
from app.models.enums import UserRole
from app.models.user import User
from app.schemas.controller import ControllerClientCreate, ControllerClientCreated, ControllerClientOut
from app.schemas.user import CreateManagerRequest, UserOut, UserStatusUpdate
from app.schemas.vehicle import AdminVehicleOut
from app.services import auth_service, controller_service, user_service, vehicle_service

router = APIRouter(prefix="/admin", tags=["admin"])


@router.post("/managers", response_model=UserOut, status_code=status.HTTP_201_CREATED)
async def create_manager(
    body: CreateManagerRequest, admin: User = Depends(require_admin), db: AsyncSession = Depends(get_db)
) -> User:
    return await auth_service.create_user(
        db, email=body.email, password=body.password, full_name=body.full_name,
        role=UserRole.MANAGER, actor=admin,
    )


@router.patch("/users/{user_id}/status", response_model=UserOut)
async def set_user_status(
    user_id: uuid.UUID,
    body: UserStatusUpdate,
    admin: User = Depends(require_admin),
    db: AsyncSession = Depends(get_db),
) -> User:
    return await user_service.set_active(db, admin, user_id, body.is_active)


@router.get("/vehicles/{vehicle_id}", response_model=AdminVehicleOut)
async def get_vehicle(
    vehicle_id: uuid.UUID, _: User = Depends(require_admin), db: AsyncSession = Depends(get_db)
) -> AdminVehicleOut:
    return await vehicle_service.get_admin_vehicle(db, vehicle_id)


@router.post("/controller-clients", response_model=ControllerClientCreated, status_code=status.HTTP_201_CREATED)
async def create_controller_client(
    body: ControllerClientCreate, admin: User = Depends(require_admin), db: AsyncSession = Depends(get_db)
) -> ControllerClientCreated:
    return await controller_service.create_client(db, admin, body)


@router.get("/controller-clients", response_model=list[ControllerClientOut])
async def list_controller_clients(
    _: User = Depends(require_admin), db: AsyncSession = Depends(get_db)
) -> list[ControllerClientOut]:
    return await controller_service.list_clients(db)


@router.post("/controller-clients/{client_id}/revoke", response_model=ControllerClientOut)
async def revoke_controller_client(
    client_id: uuid.UUID, admin: User = Depends(require_admin), db: AsyncSession = Depends(get_db)
) -> ControllerClientOut:
    return await controller_service.revoke_client(db, admin, client_id)
