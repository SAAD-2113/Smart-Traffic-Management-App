from datetime import datetime

from pydantic import Field

from app.schemas.common import ApiInput, ApiModel


class DemoStartRequest(ApiInput):
    vehicles: int = Field(default=30, ge=1, le=500)
    include_emergency_vehicle: bool = True
    seed: int | None = Field(default=None, ge=0, le=2**31 - 1)


class DemoStatusOut(ApiModel):
    enabled: bool
    running: bool
    started_at: datetime | None
    vehicles: int
    active_vehicles: int
    emergency_active: bool
    simulated_seconds: float
    note: str = "Simulated data. Vehicles are marked isSimulated and use SIM- codes."
