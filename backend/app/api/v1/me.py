from fastapi import APIRouter, Depends
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import get_current_user
from app.db.session import get_db
from app.models.user import User
from app.schemas.user import UpdateProfileRequest, UserOut
from app.schemas.vehicle import OwnerVehicleOut
from app.services import user_service, vehicle_service

router = APIRouter(prefix="/me", tags=["me"])


@router.get("", response_model=UserOut)
async def get_me(user: User = Depends(get_current_user)) -> User:
    return user


@router.patch("", response_model=UserOut)
async def update_me(
    body: UpdateProfileRequest,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
) -> User:
    return await user_service.update_profile(db, user, body)


@router.get("/vehicles", response_model=list[OwnerVehicleOut])
async def my_vehicles(
    user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)
) -> list[OwnerVehicleOut]:
    return await vehicle_service.list_owner_vehicles(db, user)
