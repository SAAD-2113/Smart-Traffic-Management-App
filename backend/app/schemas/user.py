import uuid
from datetime import datetime

from pydantic import EmailStr, Field, field_validator

from app.models.enums import UserRole
from app.schemas.common import ApiInput, ApiModel

PHONE_PATTERN = r"^\+[1-9]\d{7,14}$"  # E.164, e.g. +923001234567


def validate_password_strength(value: str) -> str:
    if not 10 <= len(value) <= 128:
        raise ValueError("Password must be 10 to 128 characters long.")
    if not any(c.isalpha() for c in value) or not any(c.isdigit() for c in value):
        raise ValueError("Password must contain at least one letter and one digit.")
    return value


class UserOut(ApiModel):
    id: uuid.UUID
    email: str
    phone: str | None
    full_name: str
    role: UserRole
    is_active: bool
    created_at: datetime


class UpdateProfileRequest(ApiInput):
    full_name: str | None = Field(default=None, min_length=2, max_length=120)
    phone: str | None = Field(default=None, pattern=PHONE_PATTERN)


class CreateManagerRequest(ApiInput):
    email: EmailStr
    password: str
    full_name: str = Field(min_length=2, max_length=120)

    @field_validator("email")
    @classmethod
    def _lower(cls, v: str) -> str:
        return v.lower()

    @field_validator("password")
    @classmethod
    def _strong(cls, v: str) -> str:
        return validate_password_strength(v)


class UserStatusUpdate(ApiInput):
    is_active: bool
