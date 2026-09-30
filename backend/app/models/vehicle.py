import uuid
from datetime import datetime

from sqlalchemy import Boolean, ForeignKey, Index, Integer, String, UniqueConstraint, Uuid, text
from sqlalchemy.orm import Mapped, mapped_column

from app.core.time import utcnow
from app.db.base import Base, TimestampMixin
from app.db.types import UTCDateTime, enum_column
from app.models.enums import (
    AuthorizationStatus,
    DevicePlatform,
    DeviceStatus,
    VehicleStatus,
    VehicleType,
)


class Vehicle(TimestampMixin, Base):
    """The vehicle identity. `id` is the real key; `code` (VH-0012) is only a display label."""

    __tablename__ = "vehicles"

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)
    code: Mapped[str] = mapped_column(String(16), unique=True, nullable=False)
    owner_user_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("users.id", ondelete="RESTRICT"), index=True, nullable=False
    )
    vehicle_type: Mapped[VehicleType] = mapped_column(enum_column(VehicleType), nullable=False)
    display_name: Mapped[str] = mapped_column(String(60), nullable=False)
    # Only collected for emergency vehicles (verification); visible to the owner and ADMIN only.
    registration_number: Mapped[str | None] = mapped_column(String(20))
    is_simulated: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    status: Mapped[VehicleStatus] = mapped_column(
        enum_column(VehicleStatus), nullable=False, default=VehicleStatus.ACTIVE
    )


class EmergencyAuthorization(Base):
    __tablename__ = "emergency_authorizations"

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)
    vehicle_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("vehicles.id", ondelete="CASCADE"), index=True, nullable=False
    )
    status: Mapped[AuthorizationStatus] = mapped_column(
        enum_column(AuthorizationStatus), nullable=False, default=AuthorizationStatus.PENDING
    )
    requested_by: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id"), nullable=False)
    reviewed_by: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("users.id"))
    reviewed_at: Mapped[datetime | None] = mapped_column(UTCDateTime())
    valid_until: Mapped[datetime | None] = mapped_column(UTCDateTime())
    notes: Mapped[str | None] = mapped_column(String(500))
    created_at: Mapped[datetime] = mapped_column(UTCDateTime(), default=utcnow, nullable=False)


class Device(Base):
    """One app installation bound to one vehicle. A phone can be replaced without changing the vehicle."""

    __tablename__ = "devices"
    __table_args__ = (
        UniqueConstraint("vehicle_id", "installation_id"),
        # At most one ACTIVE device per vehicle, enforced by the database itself.
        Index(
            "ix_devices_one_active_per_vehicle",
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
    installation_id: Mapped[str] = mapped_column(String(64), index=True, nullable=False)
    platform: Mapped[DevicePlatform] = mapped_column(enum_column(DevicePlatform), nullable=False)
    model: Mapped[str | None] = mapped_column(String(80))
    app_version: Mapped[str | None] = mapped_column(String(20))
    status: Mapped[DeviceStatus] = mapped_column(
        enum_column(DeviceStatus), nullable=False, default=DeviceStatus.ACTIVE
    )
    bound_at: Mapped[datetime] = mapped_column(UTCDateTime(), default=utcnow, nullable=False)
    unbound_at: Mapped[datetime | None] = mapped_column(UTCDateTime())
    last_seen_at: Mapped[datetime | None] = mapped_column(UTCDateTime())


class CodeCounter(Base):
    """Per-prefix counter for human-readable vehicle codes (VH-0001, EV-0001, SIM-0001)."""

    __tablename__ = "code_counters"

    prefix: Mapped[str] = mapped_column(String(8), primary_key=True)
    last_value: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
