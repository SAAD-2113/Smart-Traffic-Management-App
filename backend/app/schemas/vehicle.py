import re
import uuid
from datetime import datetime
from pydantic import Field, field_validator, model_validator

from app.models.enums import (
    AuthorizationStatus,
    DevicePlatform,
    DeviceStatus,
    VehicleStatus,
    VehicleType,
)
from app.schemas.auth import INSTALLATION_ID_PATTERN
from app.schemas.common import ApiInput, ApiModel


class VehicleCreate(ApiInput):
    vehicle_type: VehicleType = VehicleType.NORMAL
    display_name: str = Field(min_length=1, max_length=60)
    registration_number: str | None = Field(default=None, max_length=24)

    @field_validator("registration_number")
    @classmethod
    def _normalise_registration(cls, v: str | None) -> str | None:
        if v is None:
            return None
        v = v.upper().replace(" ", "")
        if not re.fullmatch(r"[A-Z0-9-]{2,20}", v):
            raise ValueError("Registration number may contain only letters, digits and '-'.")
        return v

    @model_validator(mode="after")
    def _registration_required_for_emergency(self) -> "VehicleCreate":
        if self.vehicle_type.is_emergency and not self.registration_number:
            raise ValueError("registrationNumber is required for emergency vehicle types.")
        return self


class EmergencyAuthorizationOut(ApiModel):
    status: AuthorizationStatus
    valid_until: datetime | None
    reviewed_at: datetime | None


class OwnerVehicleOut(ApiModel):
    """What the vehicle's owner sees."""

    id: uuid.UUID
    code: str
    vehicle_type: VehicleType
    display_name: str
    registration_number: str | None
    is_simulated: bool
    status: VehicleStatus
    emergency_authorization: EmergencyAuthorizationOut | None
    emergency_authorized: bool
    created_at: datetime


class ManagerVehicleOut(ApiModel):
    """What a manager sees: operational fields only, no owner identity or personal labels."""

    id: uuid.UUID
    code: str
    vehicle_type: VehicleType
    is_simulated: bool
    status: VehicleStatus
    emergency_authorized: bool
    created_at: datetime


class AdminVehicleOut(OwnerVehicleOut):
    owner_user_id: uuid.UUID


class VehicleStatusUpdate(ApiInput):
    status: VehicleStatus
    reason: str = Field(min_length=3, max_length=300)

    @field_validator("status")
    @classmethod
    def _not_retired(cls, v: VehicleStatus) -> VehicleStatus:
        if v == VehicleStatus.RETIRED:
            raise ValueError("Managers can only set ACTIVE or SUSPENDED.")
        return v


class DeviceBindRequest(ApiInput):
    installation_id: str = Field(pattern=INSTALLATION_ID_PATTERN)
    platform: DevicePlatform
    model: str | None = Field(default=None, max_length=80)
    app_version: str | None = Field(default=None, max_length=20)


class DeviceOut(ApiModel):
    id: uuid.UUID
    installation_id: str
    platform: DevicePlatform
    model: str | None
    app_version: str | None
    status: DeviceStatus
    bound_at: datetime
    last_seen_at: datetime | None
