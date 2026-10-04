from datetime import datetime

from pydantic import Field

from app.schemas.common import ApiInput, ApiModel


class DemoStartRequest(ApiInput):
    vehicles: int = Field(default=30, ge=1, le=500)
    include_emergency_vehicle: bool = True
    seed: int | None = Field(default=None, ge=0, le=2**31 - 1)


class DemoSurgeRequest(ApiInput):
    intersection_code: str = Field(min_length=1, max_length=16)
    duration_s: float = Field(default=480, ge=60, le=1800)


class DemoStatusOut(ApiModel):
    enabled: bool
    running: bool
    started_at: datetime | None
    vehicles: int
    active_vehicles: int
    emergency_active: bool
    simulated_seconds: float
    surge_intersection_code: str | None = None
    surge_remaining_s: float = 0.0
    note: str = "Simulated data. Vehicles are marked isSimulated and use SIM- codes."
