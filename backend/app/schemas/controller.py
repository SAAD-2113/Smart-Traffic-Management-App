import uuid
from datetime import datetime

from pydantic import Field

from app.models.enums import ControllerClientKind
from app.schemas.common import ApiInput, ApiModel


class ControllerClientCreate(ApiInput):
    name: str = Field(min_length=3, max_length=80)
    kind: ControllerClientKind
    intersection_ids: list[uuid.UUID] = Field(min_length=1, max_length=20)


class ControllerClientOut(ApiModel):
    id: uuid.UUID
    name: str
    kind: ControllerClientKind
    key_prefix: str
    intersection_ids: list[uuid.UUID]
    created_at: datetime
    last_seen_at: datetime | None
    revoked_at: datetime | None


class ControllerClientCreated(ControllerClientOut):
    api_key: str = Field(description="Shown once. Store it on the device; only its hash is kept.")


class ControllerPingOut(ApiModel):
    client_id: uuid.UUID
    name: str
    intersection_codes: list[str]
    server_time: datetime


class ExternalVehicleIn(ApiInput):
    external_id: str = Field(min_length=1, max_length=64)
    lat: float = Field(ge=-90, le=90)
    lon: float = Field(ge=-180, le=180)
    speed_mps: float | None = Field(default=None, ge=0, le=100)
    heading_deg: float | None = Field(default=None, ge=0, lt=360)
    accuracy_m: float = Field(default=2.0, gt=0, le=100)
    vehicle_type: str = Field(default="NORMAL", pattern=r"^[A-Z_]{1,16}$")
    emergency: bool = False


class DetectorCountIn(ApiInput):
    intersection_code: str = Field(min_length=1, max_length=16)
    approach_name: str = Field(min_length=1, max_length=40)
    vehicle_count: int = Field(ge=0, le=500)
    queue_length_m: float | None = Field(default=None, ge=0, le=5000)


class ObservationBatch(ApiInput):
    """Vehicle positions (SUMO) and/or approach counts (camera, sensor) from a machine client."""

    observed_at: datetime | None = None
    vehicles: list[ExternalVehicleIn] = Field(default_factory=list, max_length=5000)
    counts: list[DetectorCountIn] = Field(default_factory=list, max_length=200)


class ObservationBatchResult(ApiModel):
    accepted_vehicles: int
    accepted_counts: int
    ignored_counts: int
    source: str
