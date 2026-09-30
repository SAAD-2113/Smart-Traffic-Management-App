import uuid

from sqlalchemy import func, select, update
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.dialects.sqlite import insert as sqlite_insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.enums import VehicleStatus, VehicleType
from app.models.vehicle import CodeCounter, EmergencyAuthorization, Vehicle


async def allocate_code(db: AsyncSession, prefix: str) -> str:
    """Atomically take the next number for a prefix. Safe under concurrent registrations."""
    dialect = db.get_bind().dialect.name
    insert = pg_insert if dialect == "postgresql" else sqlite_insert
    await db.execute(
        insert(CodeCounter)
        .values(prefix=prefix, last_value=0)
        .on_conflict_do_nothing(index_elements=["prefix"])
    )
    value = (
        await db.execute(
            update(CodeCounter)
            .where(CodeCounter.prefix == prefix)
            .values(last_value=CodeCounter.last_value + 1)
            .returning(CodeCounter.last_value)
        )
    ).scalar_one()
    return f"{prefix}-{value:04d}"


async def count_owned(db: AsyncSession, owner_id: uuid.UUID) -> int:
    return await db.scalar(
        select(func.count())
        .select_from(Vehicle)
        .where(Vehicle.owner_user_id == owner_id, Vehicle.status != VehicleStatus.RETIRED)
    ) or 0


async def list_owned(db: AsyncSession, owner_id: uuid.UUID) -> list[Vehicle]:
    rows = await db.scalars(
        select(Vehicle).where(Vehicle.owner_user_id == owner_id).order_by(Vehicle.created_at)
    )
    return list(rows)


async def list_filtered(
    db: AsyncSession,
    *,
    vehicle_type: VehicleType | None,
    status: VehicleStatus | None,
    is_simulated: bool | None,
    limit: int,
    offset: int,
) -> tuple[list[Vehicle], int]:
    conditions = []
    if vehicle_type is not None:
        conditions.append(Vehicle.vehicle_type == vehicle_type)
    if status is not None:
        conditions.append(Vehicle.status == status)
    if is_simulated is not None:
        conditions.append(Vehicle.is_simulated == is_simulated)

    total = await db.scalar(select(func.count()).select_from(Vehicle).where(*conditions)) or 0
    rows = await db.scalars(
        select(Vehicle).where(*conditions).order_by(Vehicle.code).limit(limit).offset(offset)
    )
    return list(rows), total


async def latest_authorizations(
    db: AsyncSession, vehicle_ids: list[uuid.UUID]
) -> dict[uuid.UUID, EmergencyAuthorization]:
    if not vehicle_ids:
        return {}
    rows = await db.scalars(
        select(EmergencyAuthorization)
        .where(EmergencyAuthorization.vehicle_id.in_(vehicle_ids))
        .order_by(EmergencyAuthorization.created_at)
    )
    latest: dict[uuid.UUID, EmergencyAuthorization] = {}
    for row in rows:
        latest[row.vehicle_id] = row  # ordered oldest -> newest, so the last one wins
    return latest
