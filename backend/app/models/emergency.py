import uuid
from datetime import datetime

from sqlalchemy import ForeignKey, Index, String, Uuid, text
from sqlalchemy.orm import Mapped, mapped_column

from app.core.time import utcnow
from app.db.base import Base
from app.db.types import UTCDateTime, enum_column
from app.models.enums import EmergencyEndReason, EmergencyEventStatus


class EmergencyEvent(Base):
    """One period during which an authorised vehicle had emergency mode active."""

    __tablename__ = "emergency_events"
    __table_args__ = (
        # At most one ACTIVE emergency per vehicle, enforced by the database.
        Index(
            "ix_emergency_events_one_active_per_vehicle",
            "vehicle_id",
            unique=True,
            postgresql_where=text("status = 'ACTIVE'"),
            sqlite_where=text("status = 'ACTIVE'"),
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)
    vehicle_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("vehicles.id", ondelete="CASCADE"), index=True, nullable=False
    )
    session_id: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("tracking_sessions.id", ondelete="SET NULL"))
    status: Mapped[EmergencyEventStatus] = mapped_column(
        enum_column(EmergencyEventStatus), nullable=False, default=EmergencyEventStatus.ACTIVE
    )
    started_at: Mapped[datetime] = mapped_column(UTCDateTime(), default=utcnow, index=True, nullable=False)
    started_by: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("users.id", ondelete="SET NULL"))
    ended_at: Mapped[datetime | None] = mapped_column(UTCDateTime())
    end_reason: Mapped[EmergencyEndReason | None] = mapped_column(enum_column(EmergencyEndReason))
    ended_by: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("users.id", ondelete="SET NULL"))
    note: Mapped[str | None] = mapped_column(String(300))
