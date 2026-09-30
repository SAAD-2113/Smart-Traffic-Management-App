import uuid

from fastapi import APIRouter, Depends, status
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import require_manager
from app.db.session import get_db
from app.models.enums import IntersectionStatus
from app.models.intersection import Intersection, IntersectionApproach, IntersectionLink
from app.models.user import User
from app.schemas.intersection import (
    ApproachCreate,
    ApproachOut,
    IntersectionCreate,
    IntersectionDetailOut,
    IntersectionOut,
    IntersectionUpdate,
    LinkCreate,
    LinkOut,
)
from app.services import intersection_service

router = APIRouter(prefix="/intersections", tags=["intersections"])


@router.get("", response_model=list[IntersectionOut])
async def list_intersections(
    status: IntersectionStatus | None = None,
    _: User = Depends(require_manager),
    db: AsyncSession = Depends(get_db),
) -> list[Intersection]:
    return await intersection_service.list_intersections(db, status)


@router.get("/{intersection_id}", response_model=IntersectionDetailOut)
async def get_intersection(
    intersection_id: uuid.UUID, _: User = Depends(require_manager), db: AsyncSession = Depends(get_db)
) -> IntersectionDetailOut:
    return await intersection_service.get_detail(db, intersection_id)


@router.post("", response_model=IntersectionOut, status_code=status.HTTP_201_CREATED)
async def create_intersection(
    body: IntersectionCreate, user: User = Depends(require_manager), db: AsyncSession = Depends(get_db)
) -> Intersection:
    return await intersection_service.create(db, user, body)


@router.patch("/{intersection_id}", response_model=IntersectionOut)
async def update_intersection(
    intersection_id: uuid.UUID,
    body: IntersectionUpdate,
    user: User = Depends(require_manager),
    db: AsyncSession = Depends(get_db),
) -> Intersection:
    return await intersection_service.update(db, user, intersection_id, body)


@router.delete("/{intersection_id}", status_code=status.HTTP_204_NO_CONTENT)
async def deactivate_intersection(
    intersection_id: uuid.UUID, user: User = Depends(require_manager), db: AsyncSession = Depends(get_db)
) -> None:
    await intersection_service.deactivate(db, user, intersection_id)


@router.post("/{intersection_id}/approaches", response_model=ApproachOut, status_code=status.HTTP_201_CREATED)
async def add_approach(
    intersection_id: uuid.UUID,
    body: ApproachCreate,
    user: User = Depends(require_manager),
    db: AsyncSession = Depends(get_db),
) -> IntersectionApproach:
    return await intersection_service.add_approach(db, user, intersection_id, body)


@router.post("/{intersection_id}/links", response_model=LinkOut, status_code=status.HTTP_201_CREATED)
async def add_link(
    intersection_id: uuid.UUID,
    body: LinkCreate,
    user: User = Depends(require_manager),
    db: AsyncSession = Depends(get_db),
) -> IntersectionLink:
    return await intersection_service.add_link(db, user, intersection_id, body)
