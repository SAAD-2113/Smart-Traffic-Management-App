"""Registration, login, token rotation and password management."""
import asyncio
import logging
import uuid
from dataclasses import dataclass
from datetime import timedelta

from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import get_settings
from app.core.errors import AppError
from app.core.security import (
    burn_password_check,
    create_access_token,
    hash_opaque_token,
    hash_password,
    new_opaque_token,
    password_needs_rehash,
    verify_password,
)
from app.core.time import utcnow
from app.models.enums import UserRole
from app.models.user import PasswordResetToken, RefreshToken, User
from app.repositories import audit_repo, token_repo, user_repo
from app.services.email import EmailMessage, get_email_sender

logger = logging.getLogger("app.auth")


@dataclass(frozen=True)
class IssuedTokens:
    access_token: str
    access_expires_in: int
    refresh_token: str
    refresh_expires_in: int


@dataclass(frozen=True)
class PasswordResetMail:
    to: str
    link: str
    expires_in_min: int


def _email_taken() -> AppError:
    return AppError(409, "EMAIL_ALREADY_REGISTERED", "An account with this email already exists.")


def _invalid_credentials() -> AppError:
    return AppError(401, "INVALID_CREDENTIALS", "Email or password is incorrect.")


async def create_user(
    db: AsyncSession,
    *,
    email: str,
    password: str,
    full_name: str,
    role: UserRole,
    phone: str | None = None,
    actor: User | None = None,
) -> User:
    email = email.strip().lower()
    if await user_repo.get_by_email(db, email) is not None:
        raise _email_taken()

    # Argon2 is deliberately slow; run it off the event loop so other requests are not blocked.
    password_hash = await asyncio.to_thread(hash_password, password)
    user = User(email=email, phone=phone, password_hash=password_hash, full_name=full_name, role=role)
    db.add(user)
    try:
        await db.flush()
    except IntegrityError as exc:  # two registrations raced for the same email
        await db.rollback()
        raise _email_taken() from exc

    await audit_repo.record(
        db,
        "user.created",
        actor_user_id=actor.id if actor else user.id,
        target_type="user",
        target_id=user.id,
        details={"role": role.value},
    )
    await db.commit()
    return user


async def _issue_tokens(
    db: AsyncSession, user: User, *, installation_id: str | None, family_id: uuid.UUID | None
) -> tuple[IssuedTokens, RefreshToken]:
    settings = get_settings()
    now = utcnow()
    family = family_id or uuid.uuid4()
    raw_refresh = new_opaque_token("rt")
    record = RefreshToken(
        user_id=user.id,
        family_id=family,
        token_hash=hash_opaque_token(raw_refresh),
        installation_id=installation_id,
        created_at=now,
        expires_at=now + timedelta(seconds=settings.refresh_token_ttl_s),
    )
    db.add(record)
    await db.flush()
    access, access_ttl = create_access_token(user.id, session_id=family)
    return IssuedTokens(access, access_ttl, raw_refresh, settings.refresh_token_ttl_s), record


async def login(
    db: AsyncSession, *, email: str, password: str, installation_id: str | None, ip: str | None
) -> tuple[User, IssuedTokens]:
    user = await user_repo.get_by_email(db, email)
    if user is None:
        await asyncio.to_thread(burn_password_check, password)
        raise _invalid_credentials()

    if not await asyncio.to_thread(verify_password, password, user.password_hash):
        await audit_repo.record(db, "auth.login_failed", target_type="user", target_id=user.id, ip=ip)
        await db.commit()
        raise _invalid_credentials()

    if not user.is_active:
        raise AppError(403, "ACCOUNT_DISABLED", "This account has been disabled.")

    if password_needs_rehash(user.password_hash):
        user.password_hash = await asyncio.to_thread(hash_password, password)
    user.last_login_at = utcnow()

    tokens, _ = await _issue_tokens(db, user, installation_id=installation_id, family_id=None)
    await audit_repo.record(
        db, "auth.login", actor_user_id=user.id, target_type="user", target_id=user.id, ip=ip
    )
    await db.commit()
    return user, tokens


async def refresh(db: AsyncSession, raw_refresh: str) -> IssuedTokens:
    """Rotate a refresh token. Presenting an already-used token revokes the whole session,
    because it means the token was copied (the legitimate app always holds the newest one)."""
    now = utcnow()
    record = await token_repo.get_refresh_by_hash(db, hash_opaque_token(raw_refresh))
    if record is None:
        raise AppError(401, "INVALID_REFRESH_TOKEN", "Refresh token is invalid.")

    if record.revoked_at is not None:
        await token_repo.revoke_family(db, record.family_id, now)
        await audit_repo.record(
            db,
            "auth.refresh_token_reuse",
            actor_user_id=record.user_id,
            target_type="session",
            target_id=record.family_id,
        )
        await db.commit()
        raise AppError(401, "REFRESH_TOKEN_REUSED", "This session was revoked. Please log in again.")

    if record.expires_at <= now:
        raise AppError(401, "REFRESH_TOKEN_EXPIRED", "Session expired. Please log in again.")

    user = await user_repo.get_by_id(db, record.user_id)
    if user is None or not user.is_active:
        await token_repo.revoke_family(db, record.family_id, now)
        await db.commit()
        raise AppError(401, "INVALID_REFRESH_TOKEN", "Refresh token is invalid.")

    tokens, new_record = await _issue_tokens(
        db, user, installation_id=record.installation_id, family_id=record.family_id
    )
    record.revoked_at = now
    record.replaced_by_id = new_record.id
    await db.commit()
    return tokens


async def logout(db: AsyncSession, raw_refresh: str) -> None:
    record = await token_repo.get_refresh_by_hash(db, hash_opaque_token(raw_refresh))
    if record is not None and record.revoked_at is None:
        await token_repo.revoke_family(db, record.family_id, utcnow())
        await audit_repo.record(
            db, "auth.logout", actor_user_id=record.user_id, target_type="session", target_id=record.family_id
        )
        await db.commit()


async def request_password_reset(db: AsyncSession, email: str) -> PasswordResetMail | None:
    """Returns the mail to send, or None. The API responds identically either way."""
    user = await user_repo.get_by_email(db, email)
    if user is None or not user.is_active:
        return None

    settings = get_settings()
    now = utcnow()
    await token_repo.invalidate_open_resets(db, user.id, now)  # only the newest link works
    raw = new_opaque_token("pr")
    db.add(
        PasswordResetToken(
            user_id=user.id,
            token_hash=hash_opaque_token(raw),
            created_at=now,
            expires_at=now + timedelta(seconds=settings.password_reset_ttl_s),
        )
    )
    await audit_repo.record(db, "auth.password_reset_requested", target_type="user", target_id=user.id)
    await db.commit()
    return PasswordResetMail(
        to=user.email,
        link=f"{settings.password_reset_url}?token={raw}",
        expires_in_min=settings.password_reset_ttl_s // 60,
    )


async def send_password_reset_email(mail: PasswordResetMail) -> None:
    body = (
        "A password reset was requested for your Smart Traffic account.\n\n"
        f"Open this link within {mail.expires_in_min} minutes to choose a new password:\n"
        f"{mail.link}\n\n"
        "If you did not request this, you can ignore this email."
    )
    try:
        await get_email_sender().send(EmailMessage(mail.to, "Reset your password", body))
    except Exception:  # never let an email failure surface to the client
        logger.exception("Failed to send password reset email")


async def reset_password(db: AsyncSession, raw_token: str, new_password: str) -> None:
    now = utcnow()
    invalid = AppError(400, "INVALID_RESET_TOKEN", "This reset link is invalid or has expired.")
    record = await token_repo.get_reset_by_hash(db, hash_opaque_token(raw_token))
    if record is None or record.used_at is not None or record.expires_at <= now:
        raise invalid
    user = await user_repo.get_by_id(db, record.user_id)
    if user is None or not user.is_active:
        raise invalid

    user.password_hash = await asyncio.to_thread(hash_password, new_password)
    record.used_at = now
    await token_repo.revoke_all_for_user(db, user.id, now)  # log out every device
    await audit_repo.record(db, "auth.password_reset", actor_user_id=user.id, target_type="user", target_id=user.id)
    await db.commit()


async def change_password(
    db: AsyncSession,
    user: User,
    *,
    session_id: uuid.UUID | None,
    current_password: str,
    new_password: str,
) -> None:
    if not await asyncio.to_thread(verify_password, current_password, user.password_hash):
        raise AppError(400, "INVALID_CURRENT_PASSWORD", "Current password is incorrect.")
    now = utcnow()
    user.password_hash = await asyncio.to_thread(hash_password, new_password)
    # Keep the session that made the change; sign out every other device.
    await token_repo.revoke_all_for_user(db, user.id, now, except_family=session_id)
    await audit_repo.record(db, "auth.password_changed", actor_user_id=user.id, target_type="user", target_id=user.id)
    await db.commit()
