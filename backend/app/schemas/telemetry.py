import uuid
from datetime import datetime
from typing import Literal

from pydantic import AwareDatetime, ConfigDict, Field

from app.models.enums import (
    GpsQuality,
    SessionEndReason,
    SpeedSource,
    TelemetrySource,
    TrackingStatus,
    TrafficZone,
    VehicleType,
)
from app.schemas.common import ApiInput, ApiModel


class TelemetryInput(ApiInput):
    """Structural validation only: types, required fields, no NaN/Infinity.

    Range and plausibility rules are applied per packet by the telemetry service, so one bad
    packet cannot make a phone's whole offline backlog undeliverable.
    """

    model_config = ConfigDict(allow_inf_nan=False)

    seq: int = Field(ge=0, le=2**31 - 1)
    recorded_at: AwareDatetime
    lat: float
    lon: float
    accuracy_m: float
    speed_mps: float | None = None
    speed_accuracy_mps: float | None = None
    speed_source: SpeedSource | None = None
    heading_deg: float | None = None
    altitude_m: float | None = None
    emergency: bool
    mocked: bool


class TelemetryBatch(ApiInput):
    session_id: uuid.UUID
    packets: list[TelemetryInput] = Field(min_length=1, max_length=500)


PacketStatus = Literal["ACCEPTED", "REJECTED"]


class PacketResult(ApiModel):
    seq: int
    status: PacketStatus
    reason: str | None = None
    live: bool | None = None
    usable: bool | None = None


class TelemetryBatchResult(ApiModel):
    accepted: int
    rejected: int
    results: list[PacketResult]
    emergency_active: bool
    server_time: datetime


class TrackingStartRequest(ApiInput):
    app_version: str | None = Field(default=None, max_length=20)


class TrackingStopRequest(ApiInput):
    session_id: uuid.UUID | None = None


class TrackingSessionOut(ApiModel):
    id: uuid.UUID
    vehicle_id: uuid.UUID
    started_at: datetime
    ended_at: datetime | None
    end_reason: SessionEndReason | None
    packet_count: int
    rejected_count: int
    distance_m: float
    max_speed_mps: float | None
    avg_speed_mps: float | None
    duration_s: float
    last_recorded_at: datetime | None


class LiveStateOut(ApiModel):
    recorded_at: datetime
    received_at: datetime
    age_s: float
    lat: float
    lon: float
    accuracy_m: float
    gps_quality: GpsQuality
    speed_mps: float | None
    heading_deg: float | None
    emergency: bool
    usable: bool
    source: TelemetrySource
    intersection_code: str | None
    approach_name: str | None
    zone: TrafficZone | None


class OwnerLatestOut(ApiModel):
    vehicle_id: uuid.UUID
    tracking_status: TrackingStatus
    session: TrackingSessionOut | None
    live: LiveStateOut | None
    emergency_active: bool


class LiveVehicleOut(ApiModel):
    """Manager view of a vehicle's live state. Operational fields only: no owner identity."""

    vehicle_id: uuid.UUID
    code: str
    vehicle_type: VehicleType
    is_simulated: bool
    emergency_authorized: bool
    emergency_active: bool
    tracking_status: TrackingStatus
    live: LiveStateOut | None


class TelemetryPointOut(ApiModel):
    recorded_at: datetime
    lat: float
    lon: float
    accuracy_m: float
    speed_mps: float | None
    heading_deg: float | None
    emergency: bool
    is_live: bool
    usable: bool
    zone: TrafficZone | None
