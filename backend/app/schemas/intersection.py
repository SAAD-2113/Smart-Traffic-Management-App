import uuid
from datetime import datetime

from pydantic import Field, model_validator

from app.models.enums import ActuatorType, ControllerType, IntersectionStatus
from app.schemas.common import ApiInput, ApiModel

CODE_PATTERN = r"^[A-Z][A-Z0-9-]{0,15}$"


class IntersectionCreate(ApiInput):
    code: str = Field(pattern=CODE_PATTERN)
    name: str = Field(min_length=2, max_length=120)
    latitude: float = Field(ge=-90, le=90)
    longitude: float = Field(ge=-180, le=180)
    radius_m: float = Field(ge=10, le=500)
    approach_radius_m: float = Field(ge=20, le=2000)
    controller_type: ControllerType = ControllerType.FIXED
    actuator: ActuatorType = ActuatorType.DISPLAY_ONLY
    sumo_tls_id: str | None = Field(default=None, max_length=64)
    assumed_penetration_rate: float = Field(default=0.05, gt=0, le=1)

    @model_validator(mode="after")
    def _approach_outside_core(self) -> "IntersectionCreate":
        if self.approach_radius_m <= self.radius_m:
            raise ValueError("approachRadiusM must be greater than radiusM.")
        return self


class IntersectionUpdate(ApiInput):
    """The code is immutable because SUMO mappings and controller scopes refer to it."""

    name: str | None = Field(default=None, min_length=2, max_length=120)
    latitude: float | None = Field(default=None, ge=-90, le=90)
    longitude: float | None = Field(default=None, ge=-180, le=180)
    radius_m: float | None = Field(default=None, ge=10, le=500)
    approach_radius_m: float | None = Field(default=None, ge=20, le=2000)
    status: IntersectionStatus | None = None
    controller_type: ControllerType | None = None
    actuator: ActuatorType | None = None
    sumo_tls_id: str | None = Field(default=None, max_length=64)
    assumed_penetration_rate: float | None = Field(default=None, gt=0, le=1)


class ApproachCreate(ApiInput):
    name: str = Field(min_length=1, max_length=40)
    travel_bearing_deg: float = Field(ge=0, lt=360)
    bearing_tolerance_deg: float = Field(default=45, gt=0, le=90)
    lanes: int = Field(default=1, ge=1, le=8)
    zone_length_m: float = Field(gt=0, le=2000)
    free_flow_speed_mps: float = Field(default=11.1, gt=0, le=40)
    upstream_intersection_id: uuid.UUID | None = None


class LinkCreate(ApiInput):
    to_intersection_id: uuid.UUID
    to_approach_id: uuid.UUID | None = None
    distance_m: float = Field(gt=0, le=20000)
    free_flow_speed_mps: float = Field(default=11.1, gt=0, le=40)


class ApproachOut(ApiModel):
    id: uuid.UUID
    name: str
    travel_bearing_deg: float
    bearing_tolerance_deg: float
    lanes: int
    zone_length_m: float
    free_flow_speed_mps: float
    upstream_intersection_id: uuid.UUID | None


class LinkOut(ApiModel):
    id: uuid.UUID
    from_intersection_id: uuid.UUID
    to_intersection_id: uuid.UUID
    to_approach_id: uuid.UUID | None
    distance_m: float
    free_flow_speed_mps: float


class IntersectionOut(ApiModel):
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
    sumo_tls_id: str | None
    assumed_penetration_rate: float
    created_at: datetime
    updated_at: datetime


class IntersectionDetailOut(IntersectionOut):
    approaches: list[ApproachOut]
    outgoing_links: list[LinkOut]
