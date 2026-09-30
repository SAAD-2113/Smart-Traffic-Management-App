import uuid
from datetime import datetime

from sqlalchemy import Boolean, Float, ForeignKey, Index, Integer, String, Uuid
from sqlalchemy.orm import Mapped, mapped_column

from app.core.time import utcnow
from app.db.base import Base
from app.db.types import BigIntPK, UTCDateTime, enum_column
from app.models.enums import GpsQuality, SessionEndReason, SpeedSource, TelemetrySource, TrafficZone


class TrackingSession(Base):
    """One tracking run (a trip) of one vehicle from one device."""

    __tablename__ = "tracking_sessions"
    __table_args__ = (Index("ix_tracking_sessions_vehicle_started", "vehicle_id", "started_at"),)

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)
    vehicle_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("vehicles.id", ondelete="CASCADE"), nullable=False)
    device_id: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("devices.id", ondelete="SET NULL"))
    source: Mapped[TelemetrySource] = mapped_column(
        enum_column(TelemetrySource), nullable=False, default=TelemetrySource.MOBILE
    )
    started_at: Mapped[datetime] = mapped_column(UTCDateTime(), default=utcnow, nullable=False)
    ended_at: Mapped[datetime | None] = mapped_column(UTCDateTime())
    end_reason: Mapped[SessionEndReason | None] = mapped_column(enum_column(SessionEndReason))

    packet_count: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    rejected_count: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    distance_m: Mapped[float] = mapped_column(Float, nullable=False, default=0.0)
    max_speed_mps: Mapped[float | None] = mapped_column(Float)

    # Last accepted fix: ordering (replay protection) and jump plausibility checks.
    last_seq: Mapped[int | None] = mapped_column(Integer)
    last_recorded_at: Mapped[datetime | None] = mapped_column(UTCDateTime())
    last_lat: Mapped[float | None] = mapped_column(Float)
    last_lon: Mapped[float | None] = mapped_column(Float)
    last_accuracy_m: Mapped[float | None] = mapped_column(Float)
    jump_streak: Mapped[int] = mapped_column(Integer, nullable=False, default=0)


class VehicleTelemetry(Base):
    """Every accepted packet (live and backfilled). Append-only; pruned by retention."""

    __tablename__ = "vehicle_telemetry"
    __table_args__ = (
        Index("ix_vehicle_telemetry_vehicle_recorded", "vehicle_id", "recorded_at"),
        Index("ix_vehicle_telemetry_received", "received_at"),
    )

    id: Mapped[int] = mapped_column(BigIntPK, primary_key=True, autoincrement=True)
    vehicle_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("vehicles.id", ondelete="CASCADE"), nullable=False)
    session_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("tracking_sessions.id", ondelete="SET NULL"), index=True
    )
    source: Mapped[TelemetrySource] = mapped_column(enum_column(TelemetrySource), nullable=False)
    seq: Mapped[int] = mapped_column(Integer, nullable=False)
    recorded_at: Mapped[datetime] = mapped_column(UTCDateTime(), nullable=False)
    received_at: Mapped[datetime] = mapped_column(UTCDateTime(), nullable=False)
    lat: Mapped[float] = mapped_column(Float, nullable=False)
    lon: Mapped[float] = mapped_column(Float, nullable=False)
    accuracy_m: Mapped[float] = mapped_column(Float, nullable=False)
    speed_mps: Mapped[float | None] = mapped_column(Float)
    speed_source: Mapped[SpeedSource | None] = mapped_column(enum_column(SpeedSource))
    heading_deg: Mapped[float | None] = mapped_column(Float)
    altitude_m: Mapped[float | None] = mapped_column(Float)
    emergency: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)  # server-decided
    is_mock: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    is_live: Mapped[bool] = mapped_column(Boolean, nullable=False)
    usable: Mapped[bool] = mapped_column(Boolean, nullable=False)
    intersection_id: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("intersections.id", ondelete="SET NULL"))
    approach_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("intersection_approaches.id", ondelete="SET NULL")
    )
    zone: Mapped[TrafficZone | None] = mapped_column(enum_column(TrafficZone))


class VehicleLiveState(Base):
    """The latest live fix of each vehicle (one row per vehicle, overwritten)."""

    __tablename__ = "vehicle_live_states"

    vehicle_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("vehicles.id", ondelete="CASCADE"), primary_key=True)
    session_id: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("tracking_sessions.id", ondelete="SET NULL"))
    source: Mapped[TelemetrySource] = mapped_column(enum_column(TelemetrySource), nullable=False)
    recorded_at: Mapped[datetime] = mapped_column(UTCDateTime(), index=True, nullable=False)
    received_at: Mapped[datetime] = mapped_column(UTCDateTime(), nullable=False)
    lat: Mapped[float] = mapped_column(Float, nullable=False)
    lon: Mapped[float] = mapped_column(Float, nullable=False)
    accuracy_m: Mapped[float] = mapped_column(Float, nullable=False)
    gps_quality: Mapped[GpsQuality] = mapped_column(enum_column(GpsQuality), nullable=False)
    speed_mps: Mapped[float | None] = mapped_column(Float)
    heading_deg: Mapped[float | None] = mapped_column(Float)
    emergency: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    usable: Mapped[bool] = mapped_column(Boolean, nullable=False)
    intersection_id: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("intersections.id", ondelete="SET NULL"))
    approach_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("intersection_approaches.id", ondelete="SET NULL")
    )
    zone: Mapped[TrafficZone | None] = mapped_column(enum_column(TrafficZone))
    note: Mapped[str | None] = mapped_column(String(80))
