"""Password hashing, access tokens (JWT) and opaque tokens (refresh, reset, controller keys)."""
import hashlib
import secrets
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

import jwt
from argon2 import PasswordHasher
from argon2.exceptions import InvalidHashError, VerificationError

from app.core.config import get_settings
from app.core.errors import AppError
from app.core.time import utcnow

_hasher = PasswordHasher()  # argon2id with the library's recommended parameters
_DUMMY_HASH = _hasher.hash("timing-equalisation-dummy-password")


def hash_password(password: str) -> str:
    return _hasher.hash(password)


def verify_password(password: str, password_hash: str) -> bool:
    try:
        return _hasher.verify(password_hash, password)
    except (VerificationError, InvalidHashError):
        return False


def password_needs_rehash(password_hash: str) -> bool:
    return _hasher.check_needs_rehash(password_hash)


def burn_password_check(password: str) -> None:
    """Spend the same time as a real check when the account does not exist."""
    verify_password(password, _DUMMY_HASH)


@dataclass(frozen=True)
class AccessClaims:
    user_id: uuid.UUID
    session_id: uuid.UUID | None  # refresh-token family this access token belongs to
    expires_at: datetime | None = None


def create_access_token(user_id: uuid.UUID, session_id: uuid.UUID) -> tuple[str, int]:
    """Only the user id and session go in the token; role is always read from the database."""
    settings = get_settings()
    now = utcnow()
    payload = {
        "sub": str(user_id),
        "sid": str(session_id),
        "type": "access",
        "iss": settings.jwt_issuer,
        "iat": now,
        "exp": now + timedelta(seconds=settings.access_token_ttl_s),
        "jti": uuid.uuid4().hex,
    }
    token = jwt.encode(payload, settings.jwt_secret.get_secret_value(), algorithm=settings.jwt_algorithm)
    return token, settings.access_token_ttl_s


def decode_access_token(token: str) -> AccessClaims:
    settings = get_settings()
    try:
        payload = jwt.decode(
            token,
            settings.jwt_secret.get_secret_value(),
            algorithms=[settings.jwt_algorithm],
            issuer=settings.jwt_issuer,
            options={"require": ["exp", "iat", "sub", "iss"]},
        )
    except jwt.ExpiredSignatureError as exc:
        raise AppError(401, "TOKEN_EXPIRED", "Access token has expired.") from exc
    except jwt.PyJWTError as exc:
        raise AppError(401, "INVALID_TOKEN", "Access token is invalid.") from exc

    if payload.get("type") != "access":
        raise AppError(401, "INVALID_TOKEN", "Access token is invalid.")
    try:
        user_id = uuid.UUID(payload["sub"])
        session_id = uuid.UUID(payload["sid"]) if payload.get("sid") else None
    except (ValueError, TypeError) as exc:
        raise AppError(401, "INVALID_TOKEN", "Access token is invalid.") from exc
    expires_at = datetime.fromtimestamp(payload["exp"], tz=timezone.utc)
    return AccessClaims(user_id=user_id, session_id=session_id, expires_at=expires_at)


def new_opaque_token(prefix: str) -> str:
    """256-bit random token. The prefix makes leaked tokens easy to recognise (rt_, pr_, stc_)."""
    return f"{prefix}_{secrets.token_urlsafe(32)}"


def hash_opaque_token(token: str) -> str:
    """Tokens are high-entropy random values, so a fast hash is sufficient (unlike passwords)."""
    return hashlib.sha256(token.encode("utf-8")).hexdigest()
