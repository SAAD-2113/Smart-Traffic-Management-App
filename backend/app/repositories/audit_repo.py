import uuid
from typing import Any

from sqlalchemy.ext.asyncio import AsyncSession

from app.core.time import utcnow
from app.models.system import AuditLog


async def record(
    db: AsyncSession,
    action: str,
    *,
    actor_user_id: uuid.UUID | None = None,
    actor_client_id: uuid.UUID | None = None,
    target_type: str | None = None,
    target_id: Any = None,
    details: dict[str, Any] | None = None,
    ip: str | None = None,
) -> None:
    """Add an audit entry to the current transaction (committed together with the change)."""
    db.add(
        AuditLog(
            action=action,
            actor_user_id=actor_user_id,
            actor_client_id=actor_client_id,
            target_type=target_type,
            target_id=str(target_id) if target_id is not None else None,
            details=details or {},
            ip=ip,
            created_at=utcnow(),
        )
    )
