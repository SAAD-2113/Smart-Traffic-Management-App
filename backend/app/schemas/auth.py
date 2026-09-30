from pydantic import EmailStr, Field, field_validator, model_validator

from app.schemas.common import ApiInput, ApiModel
from app.schemas.user import PHONE_PATTERN, UserOut, validate_password_strength

INSTALLATION_ID_PATTERN = r"^[A-Za-z0-9-]{8,64}$"


class RegisterRequest(ApiInput):
    email: EmailStr
    password: str
    full_name: str = Field(min_length=2, max_length=120)
    phone: str | None = Field(default=None, pattern=PHONE_PATTERN)

    @field_validator("email")
    @classmethod
    def _lower(cls, v: str) -> str:
        return v.lower()

    @field_validator("password")
    @classmethod
    def _strong(cls, v: str) -> str:
        return validate_password_strength(v)


class LoginRequest(ApiInput):
    email: EmailStr
    password: str = Field(min_length=1, max_length=128)
    installation_id: str | None = Field(default=None, pattern=INSTALLATION_ID_PATTERN)

    @field_validator("email")
    @classmethod
    def _lower(cls, v: str) -> str:
        return v.lower()


class RefreshRequest(ApiInput):
    refresh_token: str = Field(min_length=10, max_length=128)


class ForgotPasswordRequest(ApiInput):
    email: EmailStr

    @field_validator("email")
    @classmethod
    def _lower(cls, v: str) -> str:
        return v.lower()


class ResetPasswordRequest(ApiInput):
    token: str = Field(min_length=10, max_length=128)
    new_password: str

    @field_validator("new_password")
    @classmethod
    def _strong(cls, v: str) -> str:
        return validate_password_strength(v)


class ChangePasswordRequest(ApiInput):
    current_password: str = Field(min_length=1, max_length=128)
    new_password: str

    @field_validator("new_password")
    @classmethod
    def _strong(cls, v: str) -> str:
        return validate_password_strength(v)

    @model_validator(mode="after")
    def _different(self) -> "ChangePasswordRequest":
        if self.current_password == self.new_password:
            raise ValueError("New password must be different from the current password.")
        return self


class TokenPair(ApiModel):
    access_token: str
    access_expires_in: int
    refresh_token: str
    refresh_expires_in: int
    token_type: str = "Bearer"


class LoginResponse(TokenPair):
    user: UserOut
