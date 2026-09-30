import uuid
from datetime import datetime

from pydantic import Field

from app.models.enums import ActuatorType, ControllerType, IntersectionStatus, LightState, SignalMode
from app.schemas.common import ApiInput, ApiModel


class ObservedOut(ApiModel):
    vehicle_count: int
    stopped_count: int
    emergency_count: int
    speed_sample_count: int
    avg_speed_mps: float | None
    min_speed_mps: float | None
    max_speed_mps: float | None


class CalculatedOut(ApiModel):
    speed_ratio: float | None
    avg_waiting_time_s: float | None
    expected_arrivals_60s: int


class EstimatedOut(ApiModel):
    vehicle_count: float | None
    density_veh_per_km_lane: float | None
    penetration_rate: float = Field(description="Share of vehicles assumed to report (probe sources only).")


class ApproachTrafficOut(ApiModel):
    name: str
    observed: ObservedOut
    calculated: CalculatedOut
    estimated: EstimatedOut
    congestion_level: str
    data_quality: str
    detector_count: int | None
    max_waiting_time_s: float | None


class UpstreamOut(ApiModel):
    from_code: str
    to_approach_name: str | None
    vehicles_on_link: int
    expected_arrivals_60s: int
    estimated_arrivals_60s: float
    avg_speed_mps: float | None


class DownstreamOut(ApiModel):
    to_code: str
    congestion_level: str
    data_quality: str


class EmergencyNearOut(ApiModel):
    label: str | None
    vehicle_type: str
    approach_name: str | None
    zone: str
    distance_m: float
    eta_s: float | None
    source: str


class SignalStateOut(ApiModel):
    phase_name: str
    state: LightState
    remaining_s: float | None
    mode: SignalMode
    reported_at: datetime
    source: str


class PhaseGreenOut(ApiModel):
    phase: str
    green_s: float


class SignalDecisionOut(ApiModel):
    id: uuid.UUID | None
    intersection_code: str
    created_at: datetime
    valid_until: datetime
    algorithm: str
    cycle_s: float
    phase_greens: list[PhaseGreenOut]
    priority_phase: str | None
    reason: str
    inputs: dict
    advisory: bool = True


class IntersectionTrafficOut(ApiModel):
    id: uuid.UUID
    code: str
    name: str
    latitude: float
    longitude: float
    radius_m: float
    approach_radius_m: float
    status: IntersectionStatus
    controller_type: ControllerType
    actuator: ActuatorType
    congestion_level: str
    data_quality: str
    fully_observed: bool
    sources: list[str]
    observed: ObservedOut
    calculated: CalculatedOut
    estimated: EstimatedOut
    core_count: int
    departure_count: int
    approaches: list[ApproachTrafficOut]
    upstream: list[UpstreamOut]
    downstream: list[DownstreamOut]
    emergencies: list[EmergencyNearOut]
    signal: SignalStateOut | None
    connected: bool
    decision: SignalDecisionOut | None
    computed_at: datetime | None


class SystemStatusOut(ApiModel):
    database: str
    engine_running: bool
    engine_last_cycle_at: datetime | None
    engine_cycle_ms: float | None
    websocket_clients: int
    demo_mode: bool
    simulation_running: bool
    live_window_s: float
    external_sources: list[str]


class OverviewOut(ApiModel):
    generated_at: datetime
    total_registered_vehicles: int
    simulated_vehicles: int
    active_vehicles: int
    transmitting_vehicles: int
    emergency_vehicles: int
    average_speed_mps: float | None
    average_density_veh_per_km_lane: float | None
    total_intersections: int
    active_intersections: int
    connected_intersections: int
    congested_intersections: int
    congested_intersection_codes: list[str]
    pending_authorizations: int
    system: SystemStatusOut


class HistoryPointOut(ApiModel):
    t: datetime
    observed_vehicles: float
    estimated_vehicles: float | None
    avg_speed_mps: float | None
    avg_waiting_time_s: float | None
    congestion_rank: float | None = Field(description="Mean congestion rank in the bucket: 0 LOW .. 3 SEVERE.")
    worst_congestion: str
    emergency_count: int


class IntersectionHistoryOut(ApiModel):
    intersection_id: uuid.UUID
    code: str
    bucket_s: int
    points: list[HistoryPointOut]


class NetworkHistoryOut(ApiModel):
    bucket_s: int
    series: list[IntersectionHistoryOut]


class HistoryQuery(ApiInput):
    hours: float = Field(default=1.0, gt=0, le=24 * 7)
    bucket_s: int = Field(default=60, ge=30, le=3600)
