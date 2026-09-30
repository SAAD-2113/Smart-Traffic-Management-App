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
