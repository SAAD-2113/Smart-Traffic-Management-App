"""Machine clients (Raspberry Pi controllers, SUMO bridge, cameras) and their API keys."""
import uuid

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.core.errors import AppError, not_found
from app.core.security import hash_opaque_token, new_opaque_token
from app.core.time import utcnow
from app.models.intersection import Intersection
from app.models.system import ControllerClient
from app.models.user import User
from app.repositories import audit_repo
from app.schemas.controller import ControllerClientCreate, ControllerClientCreated, ControllerClientOut

KEY_PREFIX = "stc"


def to_out(client: ControllerClient) -> ControllerClientOut:
    return ControllerClientOut(
        id=client.id,
        name=client.name,
        kind=client.kind,
        key_prefix=client.key_prefix,
        intersection_ids=[i.id for i in client.intersections],
        created_at=client.created_at,
        last_seen_at=client.last_seen_at,
        revoked_at=client.revoked_at,
    )


async def create_client(
    db: AsyncSession, actor: User, data: ControllerClientCreate
) -> ControllerClientCreated:
    wanted = set(data.intersection_ids)
    intersections = list(await db.scalars(select(Intersection).where(Intersection.id.in_(wanted))))
    if len(intersections) != len(wanted):
        raise not_found("One or more intersections")
    if await db.scalar(select(ControllerClient.id).where(ControllerClient.name == data.name)):
        raise AppError(409, "CONTROLLER_NAME_EXISTS", f"A controller named '{data.name}' already exists.")

    raw_key = new_opaque_token(KEY_PREFIX)
    client = ControllerClient(
        name=data.name,
        kind=data.kind,
        key_prefix=raw_key[:12],
        key_hash=hash_opaque_token(raw_key),
        created_by=actor.id,
        created_at=utcnow(),
    )
    client.intersections = intersections
    db.add(client)
    await db.flush()
    await audit_repo.record(
        db, "controller.created", actor_user_id=actor.id, target_type="controller",
        target_id=client.id, details={"scope": sorted(i.code for i in intersections)},
    )
    await db.commit()
    return ControllerClientCreated(**to_out(client).model_dump(), api_key=raw_key)


async def list_clients(db: AsyncSession) -> list[ControllerClientOut]:
    rows = await db.scalars(
        select(ControllerClient)
        .options(selectinload(ControllerClient.intersections))
        .order_by(ControllerClient.name)
    )
    return [to_out(c) for c in rows]


async def revoke_client(db: AsyncSession, actor: User, client_id: uuid.UUID) -> ControllerClientOut:
    client = await db.scalar(
        select(ControllerClient)
        .where(ControllerClient.id == client_id)
        .options(selectinload(ControllerClient.intersections))
    )
    if client is None:
        raise not_found("Controller")
    if client.revoked_at is None:
        client.revoked_at = utcnow()
        await audit_repo.record(
            db, "controller.revoked", actor_user_id=actor.id, target_type="controller", target_id=client.id
        )
        await db.commit()
    return to_out(client)


async def authenticate(db: AsyncSession, raw_key: str) -> ControllerClient | None:
    client = await db.scalar(
        select(ControllerClient)
        .where(ControllerClient.key_hash == hash_opaque_token(raw_key), ControllerClient.revoked_at.is_(None))
        .options(selectinload(ControllerClient.intersections))
    )
    if client is not None:
        client.last_seen_at = utcnow()
        await db.commit()
    return client
