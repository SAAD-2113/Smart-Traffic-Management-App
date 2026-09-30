"""Intersection network configuration: intersections, approaches and directed links."""
import uuid

from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.core.errors import AppError, not_found
from app.models.enums import IntersectionStatus
from app.models.intersection import Intersection, IntersectionApproach, IntersectionLink
from app.models.user import User
from app.repositories import audit_repo
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


def _actor_id(actor: User | None) -> uuid.UUID | None:
    return actor.id if actor else None


async def _get(db: AsyncSession, intersection_id: uuid.UUID) -> Intersection:
    intersection = await db.get(Intersection, intersection_id)
    if intersection is None:
        raise not_found("Intersection")
    return intersection


async def get_by_code(db: AsyncSession, code: str) -> Intersection | None:
    return await db.scalar(select(Intersection).where(Intersection.code == code))


async def list_intersections(
    db: AsyncSession, status: IntersectionStatus | None = None
) -> list[Intersection]:
    stmt = select(Intersection).order_by(Intersection.code)
    if status is not None:
        stmt = stmt.where(Intersection.status == status)
    return list(await db.scalars(stmt))


async def get_detail(db: AsyncSession, intersection_id: uuid.UUID) -> IntersectionDetailOut:
    intersection = await db.scalar(
        select(Intersection)
        .where(Intersection.id == intersection_id)
        .options(selectinload(Intersection.approaches))
    )
    if intersection is None:
        raise not_found("Intersection")
    links = await db.scalars(
        select(IntersectionLink).where(IntersectionLink.from_intersection_id == intersection.id)
    )
    return IntersectionDetailOut(
        **IntersectionOut.model_validate(intersection).model_dump(),
        approaches=[ApproachOut.model_validate(a) for a in intersection.approaches],
        outgoing_links=[LinkOut.model_validate(link) for link in links],
    )


async def create(db: AsyncSession, actor: User | None, data: IntersectionCreate) -> Intersection:
    if await get_by_code(db, data.code) is not None:
        raise AppError(409, "INTERSECTION_CODE_EXISTS", f"Intersection {data.code} already exists.")
    intersection = Intersection(**data.model_dump())
    db.add(intersection)
    try:
        await db.flush()
    except IntegrityError as exc:
        await db.rollback()
        raise AppError(409, "INTERSECTION_CODE_EXISTS", f"Intersection {data.code} already exists.") from exc
    await audit_repo.record(
        db, "intersection.created", actor_user_id=_actor_id(actor),
        target_type="intersection", target_id=intersection.id, details={"code": data.code},
    )
    await db.commit()
    return intersection


async def update(
    db: AsyncSession, actor: User, intersection_id: uuid.UUID, data: IntersectionUpdate
) -> Intersection:
    intersection = await _get(db, intersection_id)
    changes = data.model_dump(exclude_unset=True)
    for field in ("name", "latitude", "longitude", "radius_m", "approach_radius_m", "status",
                  "controller_type", "actuator", "assumed_penetration_rate"):
        if field in changes and changes[field] is None:
            raise AppError(422, "VALIDATION_ERROR", f"{field} cannot be null.")

    radius = changes.get("radius_m", intersection.radius_m)
    approach_radius = changes.get("approach_radius_m", intersection.approach_radius_m)
    if approach_radius <= radius:
        raise AppError(422, "INVALID_GEOMETRY", "approachRadiusM must be greater than radiusM.")

    for field, value in changes.items():
        setattr(intersection, field, value)
    await audit_repo.record(
        db, "intersection.updated", actor_user_id=actor.id, target_type="intersection",
        target_id=intersection.id, details={"fields": sorted(changes)},
    )
    await db.commit()
    return intersection


async def deactivate(db: AsyncSession, actor: User, intersection_id: uuid.UUID) -> None:
    """Soft delete: history and metrics keep referring to it."""
    intersection = await _get(db, intersection_id)
    intersection.status = IntersectionStatus.INACTIVE
    await audit_repo.record(
        db, "intersection.deactivated", actor_user_id=actor.id,
        target_type="intersection", target_id=intersection.id,
    )
    await db.commit()


async def add_approach(
    db: AsyncSession, actor: User | None, intersection_id: uuid.UUID, data: ApproachCreate
) -> IntersectionApproach:
    intersection = await _get(db, intersection_id)
    if data.upstream_intersection_id is not None:
        if data.upstream_intersection_id == intersection.id:
            raise AppError(422, "INVALID_APPROACH", "An approach cannot be upstream of its own intersection.")
        await _get(db, data.upstream_intersection_id)

    exists = await db.scalar(
        select(IntersectionApproach.id).where(
            IntersectionApproach.intersection_id == intersection.id,
            IntersectionApproach.name == data.name,
        )
    )
    if exists is not None:
        raise AppError(409, "APPROACH_EXISTS", f"Approach '{data.name}' already exists here.")

    approach = IntersectionApproach(intersection_id=intersection.id, **data.model_dump())
    db.add(approach)
    await db.flush()
    await audit_repo.record(
        db, "intersection.approach_added", actor_user_id=_actor_id(actor),
        target_type="intersection", target_id=intersection.id, details={"approach": data.name},
    )
    await db.commit()
    return approach


async def add_link(
    db: AsyncSession, actor: User | None, from_id: uuid.UUID, data: LinkCreate
) -> IntersectionLink:
    source = await _get(db, from_id)
    if data.to_intersection_id == source.id:
        raise AppError(422, "INVALID_LINK", "A link must connect two different intersections.")
    target = await _get(db, data.to_intersection_id)

    if data.to_approach_id is not None:
        approach = await db.get(IntersectionApproach, data.to_approach_id)
        if approach is None or approach.intersection_id != target.id:
            raise AppError(422, "INVALID_LINK", "toApproachId must be an approach of the target intersection.")

    exists = await db.scalar(
        select(IntersectionLink.id).where(
            IntersectionLink.from_intersection_id == source.id,
            IntersectionLink.to_intersection_id == target.id,
        )
    )
    if exists is not None:
        raise AppError(409, "LINK_EXISTS", f"A link {source.code} -> {target.code} already exists.")

    link = IntersectionLink(from_intersection_id=source.id, **data.model_dump())
    db.add(link)
    await db.flush()
    await audit_repo.record(
        db, "intersection.link_added", actor_user_id=_actor_id(actor),
        target_type="intersection", target_id=source.id, details={"to": target.code},
    )
    await db.commit()
    return link
