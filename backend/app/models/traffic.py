import uuid
from datetime import datetime

from sqlalchemy import Float, ForeignKey, Index, Integer, String, Text, Uuid
from sqlalchemy.orm import Mapped, mapped_column

from app.core.time import utcnow
from app.db.base import Base
from app.db.types import BigIntPK, JSONType, UTCDateTime, enum_column
from app.models.enums import LightState, SignalMode


class TrafficMetric(Base):
    """Periodic snapshot of engine output for history and charts.

    approach_id NULL means the row describes the whole intersection.
    Column prefixes follow the metric kinds: observed_*, calc_*, est_*.
    """

    __tablename__ = "traffic_metrics"
    __table_args__ = (Index("ix_traffic_metrics_intersection_time", "intersection_id", "window_end"),)

    id: Mapped[int] = mapped_column(BigIntPK, primary_key=True, autoincrement=True)
    intersection_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("intersections.id", ondelete="CASCADE"), nullable=False
    )
    approach_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("intersection_approaches.id", ondelete="CASCADE")
    )
    window_end: Mapped[datetime] = mapped_column(UTCDateTime(), nullable=False)

    observed_vehicle_count: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    observed_stopped_count: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    observed_emergency_count: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    observed_avg_speed_mps: Mapped[float | None] = mapped_column(Float)
    observed_min_speed_mps: Mapped[float | None] = mapped_column(Float)
    observed_max_speed_mps: Mapped[float | None] = mapped_column(Float)
    calc_speed_ratio: Mapped[float | None] = mapped_column(Float)
    calc_avg_waiting_time_s: Mapped[float | None] = mapped_column(Float)
    calc_expected_arrivals_60s: Mapped[int | None] = mapped_column(Integer)
    est_vehicle_count: Mapped[float | None] = mapped_column(Float)
    est_density_veh_per_km_lane: Mapped[float | None] = mapped_column(Float)
    congestion_level: Mapped[str] = mapped_column(String(16), nullable=False)
    data_quality: Mapped[str] = mapped_column(String(16), nullable=False)
    sources: Mapped[list] = mapped_column(JSONType, nullable=False, default=list)


class SignalPlanConfig(Base):
    """The signal plan (phases and safety limits) configured for one intersection."""

    __tablename__ = "signal_plans"

    intersection_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("intersections.id", ondelete="CASCADE"), primary_key=True
    )
    phases: Mapped[list] = mapped_column(JSONType, nullable=False)
    min_cycle_s: Mapped[float] = mapped_column(Float, nullable=False, default=40.0)
    max_cycle_s: Mapped[float] = mapped_column(Float, nullable=False, default=120.0)
    updated_by: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("users.id", ondelete="SET NULL"))
    updated_at: Mapped[datetime] = mapped_column(UTCDateTime(), default=utcnow, onupdate=utcnow, nullable=False)


class SignalDecisionRecord(Base):
    """An advisory decision from the adaptive controller. Actuators ignore it after valid_until."""

    __tablename__ = "signal_decisions"
    __table_args__ = (Index("ix_signal_decisions_intersection_created", "intersection_id", "created_at"),)

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)
    intersection_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("intersections.id", ondelete="CASCADE"), nullable=False
    )
    created_at: Mapped[datetime] = mapped_column(UTCDateTime(), nullable=False)
    valid_until: Mapped[datetime] = mapped_column(UTCDateTime(), nullable=False)
    algorithm: Mapped[str] = mapped_column(String(32), nullable=False)
    cycle_s: Mapped[float] = mapped_column(Float, nullable=False)
    phase_greens: Mapped[list] = mapped_column(JSONType, nullable=False)
    priority_phase: Mapped[str | None] = mapped_column(String(64))
    reason: Mapped[str] = mapped_column(Text, nullable=False)
    inputs: Mapped[dict] = mapped_column(JSONType, nullable=False, default=dict)


class SignalStateRecord(Base):
    """What an actuator reports it is actually showing. Stored on change plus a heartbeat."""

    __tablename__ = "signal_states"
    __table_args__ = (Index("ix_signal_states_intersection_reported", "intersection_id", "reported_at"),)

    id: Mapped[int] = mapped_column(BigIntPK, primary_key=True, autoincrement=True)
    intersection_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("intersections.id", ondelete="CASCADE"), nullable=False
    )
    reported_at: Mapped[datetime] = mapped_column(UTCDateTime(), nullable=False)
    received_at: Mapped[datetime] = mapped_column(UTCDateTime(), nullable=False)
    phase_name: Mapped[str] = mapped_column(String(64), nullable=False)
    state: Mapped[LightState] = mapped_column(enum_column(LightState), nullable=False)
    remaining_s: Mapped[float | None] = mapped_column(Float)
    mode: Mapped[SignalMode] = mapped_column(enum_column(SignalMode), nullable=False)
    decision_id: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("signal_decisions.id", ondelete="SET NULL"))
    client_id: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("controller_clients.id", ondelete="SET NULL"))
    source: Mapped[str] = mapped_column(String(16), nullable=False, default="CONTROLLER")
