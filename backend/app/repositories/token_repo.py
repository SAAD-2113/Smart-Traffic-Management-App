import uuid
from datetime import datetime

from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.user import PasswordResetToken, RefreshToken


async def get_refresh_by_hash(db: AsyncSession, token_hash: str) -> RefreshToken | None:
    return await db.scalar(select(RefreshToken).where(RefreshToken.token_hash == token_hash))


async def revoke_family(db: AsyncSession, family_id: uuid.UUID, now: datetime) -> None:
    await db.execute(
        update(RefreshToken)
        .where(RefreshToken.family_id == family_id, RefreshToken.revoked_at.is_(None))
        .values(revoked_at=now)
    )


async def revoke_all_for_user(
    db: AsyncSession, user_id: uuid.UUID, now: datetime, *, except_family: uuid.UUID | None = None
) -> None:
    stmt = update(RefreshToken).where(
        RefreshToken.user_id == user_id, RefreshToken.revoked_at.is_(None)
    )
    if except_family is not None:
        stmt = stmt.where(RefreshToken.family_id != except_family)
    await db.execute(stmt.values(revoked_at=now))


async def get_reset_by_hash(db: AsyncSession, token_hash: str) -> PasswordResetToken | None:
    return await db.scalar(
        select(PasswordResetToken).where(PasswordResetToken.token_hash == token_hash)
    )


async def invalidate_open_resets(db: AsyncSession, user_id: uuid.UUID, now: datetime) -> None:
    await db.execute(
        update(PasswordResetToken)
        .where(PasswordResetToken.user_id == user_id, PasswordResetToken.used_at.is_(None))
        .values(used_at=now)
    )
