"""Digital V2I: an admin phone hosts a digital intersection (the firmware v3 twin); user phones
join it as vehicles. Roles, vehicle ids and the emergency flag live here, never on the phone."""
import uuid
from datetime import datetime

from sqlalchemy import Float, ForeignKey, Index, Integer, String, UniqueConstraint, Uuid
from sqlalchemy.orm import Mapped, mapped_column

from app.core.time import utcnow
from app.db.base import Base, TimestampMixin
from app.db.types import UTCDateTime, enum_column
from app.models.enums import V2IEmergencyStatus, V2ISessionStatus


class V2IProfile(TimestampMixin, Base):
    """Per END_USER account: the V2I vehicle id (1001..65535) and the emergency authorisation."""

    __tablename__ = "v2i_profiles"

    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), primary_key=True)
    vehicle_id: Mapped[int] = mapped_column(Integer, unique=True, nullable=False)
    emergency_status: Mapped[V2IEmergencyStatus] = mapped_column(
        enum_column(V2IEmergencyStatus), nullable=False, default=V2IEmergencyStatus.NONE
    )
    emergency_reason: Mapped[str | None] = mapped_column(String(200))  # the user's request note
    emergency_requested_at: Mapped[datetime | None] = mapped_column(UTCDateTime())
    emergency_decided_at: Mapped[datetime | None] = mapped_column(UTCDateTime())
    emergency_decided_by: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("users.id", ondelete="SET NULL"))

    @property
    def emergency(self) -> bool:
        return self.emergency_status == V2IEmergencyStatus.APPROVED


class V2ISession(Base):
    """A digital intersection hosted by one admin/manager phone."""

    __tablename__ = "v2i_sessions"
    __table_args__ = (Index("ix_v2i_sessions_host_status", "host_user_id", "status"),)

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)
    name: Mapped[str] = mapped_column(String(60), nullable=False)
    join_code: Mapped[str] = mapped_column(String(8), unique=True, nullable=False)
    host_user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), nullable=False)
    center_lat: Mapped[float] = mapped_column(Float, nullable=False)
    center_lon: Mapped[float] = mapped_column(Float, nullable=False)
    status: Mapped[V2ISessionStatus] = mapped_column(
        enum_column(V2ISessionStatus), nullable=False, default=V2ISessionStatus.OPEN
    )
    created_at: Mapped[datetime] = mapped_column(UTCDateTime(), default=utcnow, nullable=False)
    closed_at: Mapped[datetime | None] = mapped_column(UTCDateTime())


class V2IMember(Base):
    """A vehicle account that joined a session with its code."""

    __tablename__ = "v2i_members"
    __table_args__ = (UniqueConstraint("session_id", "user_id"),)

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)
    session_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("v2i_sessions.id", ondelete="CASCADE"), nullable=False)
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True, nullable=False)
    joined_at: Mapped[datetime] = mapped_column(UTCDateTime(), default=utcnow, nullable=False)
