import uuid
from datetime import datetime

from sqlalchemy import Column, ForeignKey, String, Table, Uuid
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.core.time import utcnow
from app.db.base import Base
from app.db.types import BigIntPK, JSONType, UTCDateTime, enum_column
from app.models.enums import ControllerClientKind
from app.models.intersection import Intersection

controller_client_scopes = Table(
    "controller_client_scopes",
    Base.metadata,
    Column("client_id", Uuid, ForeignKey("controller_clients.id", ondelete="CASCADE"), primary_key=True),
    Column("intersection_id", Uuid, ForeignKey("intersections.id", ondelete="CASCADE"), primary_key=True),
)


class ControllerClient(Base):
    """A machine client: a Raspberry Pi intersection controller, the SUMO bridge, or a camera.

    Authenticates with an API key (only its hash is stored) and may act only on the
    intersections in its scope.
    """

    __tablename__ = "controller_clients"

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)
    name: Mapped[str] = mapped_column(String(80), unique=True, nullable=False)
    kind: Mapped[ControllerClientKind] = mapped_column(enum_column(ControllerClientKind), nullable=False)
    key_prefix: Mapped[str] = mapped_column(String(12), nullable=False)
    key_hash: Mapped[str] = mapped_column(String(64), unique=True, nullable=False)
    created_by: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("users.id", ondelete="SET NULL"))
    created_at: Mapped[datetime] = mapped_column(UTCDateTime(), default=utcnow, nullable=False)
    last_seen_at: Mapped[datetime | None] = mapped_column(UTCDateTime())
    revoked_at: Mapped[datetime | None] = mapped_column(UTCDateTime())

    intersections: Mapped[list[Intersection]] = relationship(
        secondary=controller_client_scopes, lazy="raise"
    )


class AuditLog(Base):
    __tablename__ = "audit_logs"

    id: Mapped[int] = mapped_column(BigIntPK, primary_key=True, autoincrement=True)
    action: Mapped[str] = mapped_column(String(64), index=True, nullable=False)
    actor_user_id: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("users.id", ondelete="SET NULL"))
    actor_client_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("controller_clients.id", ondelete="SET NULL")
    )
    target_type: Mapped[str | None] = mapped_column(String(32))
    target_id: Mapped[str | None] = mapped_column(String(64))
    details: Mapped[dict] = mapped_column(JSONType, nullable=False, default=dict)
    ip: Mapped[str | None] = mapped_column(String(45))
    created_at: Mapped[datetime] = mapped_column(UTCDateTime(), default=utcnow, index=True, nullable=False)
