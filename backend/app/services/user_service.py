import uuid

from sqlalchemy.ext.asyncio import AsyncSession

from app.core.errors import AppError, not_found
from app.core.time import utcnow
from app.models.user import User
from app.repositories import audit_repo, token_repo, user_repo
from app.schemas.user import UpdateProfileRequest


async def update_profile(db: AsyncSession, user: User, data: UpdateProfileRequest) -> User:
    if "full_name" in data.model_fields_set and data.full_name is not None:
        user.full_name = data.full_name
    if "phone" in data.model_fields_set:
        user.phone = data.phone  # explicit null clears the phone number
    await db.commit()
    return user


async def set_active(db: AsyncSession, actor: User, user_id: uuid.UUID, is_active: bool) -> User:
    if user_id == actor.id:
        raise AppError(409, "CANNOT_MODIFY_SELF", "You cannot change the status of your own account.")
    user = await user_repo.get_by_id(db, user_id)
    if user is None:
        raise not_found("User")
    user.is_active = is_active
    if not is_active:
        await token_repo.revoke_all_for_user(db, user.id, utcnow())
    await audit_repo.record(
        db,
        "user.enabled" if is_active else "user.disabled",
        actor_user_id=actor.id,
        target_type="user",
        target_id=user.id,
    )
    await db.commit()
    return user
