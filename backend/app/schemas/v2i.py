import uuid
from datetime import datetime

from pydantic import Field

from app.models.enums import V2IEmergencyStatus, V2ISessionStatus
from app.schemas.common import ApiInput, ApiModel


class V2IMeOut(ApiModel):
    """What this account may do in Digital V2I. Decided by the server from the stored role."""

    role: str
    can_host: bool  # ADMIN / MANAGER: may host a digital intersection
    can_drive: bool  # END_USER: may join a session as a vehicle
    vehicle_id: int | None = None
    emergency_status: V2IEmergencyStatus | None = None
    emergency: bool = False


class EmergencyRequestIn(ApiInput):
    reason: str = Field(default="", max_length=200)


class SessionCreateIn(ApiInput):
    name: str = Field(min_length=1, max_length=60)
    center_lat: float = Field(ge=-90, le=90)
    center_lon: float = Field(ge=-180, le=180)


class SessionOut(ApiModel):
    id: uuid.UUID
    name: str
    join_code: str
    center_lat: float
    center_lon: float
    status: V2ISessionStatus
    created_at: datetime
    closed_at: datetime | None = None
    members: int = 0
    online_vehicles: int = 0
    intersection_online: bool = False


class JoinIn(ApiInput):
    join_code: str = Field(min_length=4, max_length=8, pattern=r"^[A-Za-z0-9]+$")


class JoinedOut(ApiModel):
    """For a vehicle: the session it joined (no join code, no host details)."""

    session_id: uuid.UUID
    name: str
    center_lat: float
    center_lon: float
    vehicle_id: int
    emergency: bool
    intersection_online: bool = False


class ProfileOut(ApiModel):
    user_id: uuid.UUID
    full_name: str
    email: str
    vehicle_id: int
    emergency_status: V2IEmergencyStatus
    emergency_reason: str | None = None
    emergency_requested_at: datetime | None = None
    emergency_decided_at: datetime | None = None


class EmergencyDecisionIn(ApiInput):
    email: str = Field(min_length=3, max_length=254)
    status: V2IEmergencyStatus


class SessionStateOut(ApiModel):
    session_id: uuid.UUID
    intersection_online: bool
    received_at: datetime | None = None
    state: dict | None = None


class TripPointOut(ApiModel):
    t: float  # seconds since the trip's first point
    lat: float
    lon: float
    speed_kmh: float | None = None
    heading_deg: float | None = None
