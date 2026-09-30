"""Authentication and authorization dependencies. Roles always come from the database."""
import uuid
from dataclasses import dataclass

from fastapi import Depends, Request
from fastapi.security import APIKeyHeader, HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.errors import AppError
from app.core.security import decode_access_token
from app.db.session import get_db
from app.models.enums import UserRole
from app.models.system import ControllerClient
from app.models.user import User
from app.repositories import user_repo
from app.services import controller_service

_bearer = HTTPBearer(auto_error=False)
_controller_key = APIKeyHeader(name="X-Controller-Key", auto_error=False)


@dataclass(frozen=True)
class AuthContext:
    user: User
    session_id: uuid.UUID | None


async def get_auth_context(
    credentials: HTTPAuthorizationCredentials | None = Depends(_bearer),
    db: AsyncSession = Depends(get_db),
) -> AuthContext:
    if credentials is None:
        raise AppError(401, "NOT_AUTHENTICATED", "Authentication is required.")
    claims = decode_access_token(credentials.credentials)
    user = await user_repo.get_by_id(db, claims.user_id)
    if user is None or not user.is_active:
        raise AppError(401, "INVALID_TOKEN", "This account is not available.")
    return AuthContext(user=user, session_id=claims.session_id)


async def get_current_user(ctx: AuthContext = Depends(get_auth_context)) -> User:
    return ctx.user


def require_roles(*roles: UserRole):
    allowed = frozenset(roles)

    async def _dependency(user: User = Depends(get_current_user)) -> User:
        if user.role not in allowed:
            raise AppError(403, "FORBIDDEN", "You do not have permission to perform this action.")
        return user

    return _dependency


require_end_user = require_roles(UserRole.END_USER)
require_manager = require_roles(UserRole.MANAGER, UserRole.ADMIN)
require_admin = require_roles(UserRole.ADMIN)


async def get_controller_client(
    api_key: str | None = Depends(_controller_key),
    db: AsyncSession = Depends(get_db),
) -> ControllerClient:
    if not api_key:
        raise AppError(401, "CONTROLLER_KEY_REQUIRED", "X-Controller-Key header is required.")
    client = await controller_service.authenticate(db, api_key)
    if client is None:
        raise AppError(401, "INVALID_CONTROLLER_KEY", "Controller key is invalid or revoked.")
    return client


def client_ip(request: Request) -> str | None:
    return request.client.host if request.client else None
