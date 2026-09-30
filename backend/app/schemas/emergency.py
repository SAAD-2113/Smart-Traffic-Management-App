import uuid
from datetime import datetime

from pydantic import AwareDatetime, Field

from app.models.enums import AuthorizationStatus, EmergencyEndReason, EmergencyEventStatus, VehicleType
from app.schemas.common import ApiInput, ApiModel


class EmergencyStartRequest(ApiInput):
    # The app sends this only after the press-and-hold and the confirmation dialog.
    confirm: bool = Field(description="Must be true; guards against accidental activation.")


class EmergencyEventOut(ApiModel):
    id: uuid.UUID
    vehicle_id: uuid.UUID
    vehicle_code: str
    vehicle_type: VehicleType
    is_simulated: bool
    status: EmergencyEventStatus
    started_at: datetime
    ended_at: datetime | None
    end_reason: EmergencyEndReason | None
    duration_s: float


class EmergencyStatusOut(ApiModel):
    """What the driver app shows on the emergency screen."""

    vehicle_id: uuid.UUID
    vehicle_type: VehicleType
    eligible_type: bool
    authorization_status: AuthorizationStatus | None
    authorized: bool
    authorization_valid_until: datetime | None
    active_event: EmergencyEventOut | None


class ActiveEmergencyOut(EmergencyEventOut):
    """Manager view: the event plus the vehicle's latest position and nearest junction."""

    lat: float | None
    lon: float | None
    speed_mps: float | None
    heading_deg: float | None
    last_fix_at: datetime | None
    intersection_code: str | None
    approach_name: str | None
    next_intersection_code: str | None
    eta_s: float | None


class AuthorizationReviewOut(ApiModel):
    id: uuid.UUID
    vehicle_id: uuid.UUID
    vehicle_code: str
    vehicle_type: VehicleType
    registration_number: str | None  # shown to managers only here, for verification
    status: AuthorizationStatus
    requested_at: datetime
    reviewed_at: datetime | None
    valid_until: datetime | None
    notes: str | None


class ApproveRequest(ApiInput):
    valid_until: AwareDatetime | None = None
    notes: str | None = Field(default=None, max_length=500)


class ReviewNotesRequest(ApiInput):
    notes: str = Field(min_length=3, max_length=500)


class EndEmergencyRequest(ApiInput):
    note: str = Field(min_length=3, max_length=300)
