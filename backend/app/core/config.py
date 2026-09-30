from functools import lru_cache
from typing import Literal

from pydantic import Field, SecretStr, field_validator, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Runtime configuration. Every value comes from the environment or backend/.env."""

    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", extra="ignore")

    app_name: str = "Smart Traffic Management API"
    environment: Literal["development", "test", "production"] = "development"
    log_level: str = "INFO"

    database_url: str
    db_echo: bool = False

    jwt_secret: SecretStr
    jwt_algorithm: Literal["HS256"] = "HS256"
    jwt_issuer: str = "smart-traffic"
    access_token_ttl_s: int = Field(default=900, ge=60, le=3600)
    refresh_token_ttl_s: int = Field(default=30 * 24 * 3600, ge=3600, le=90 * 24 * 3600)
    password_reset_ttl_s: int = Field(default=1800, ge=300, le=24 * 3600)

    cors_origins: list[str] = []
    rate_limit_enabled: bool = True
    demo_mode: bool = False
    max_vehicles_per_user: int = Field(default=3, ge=1, le=20)

    password_reset_url: str = "http://localhost:8080/reset-password"
    smtp_host: str | None = None
    smtp_port: int = 587
    smtp_username: str | None = None
    smtp_password: SecretStr | None = None
    smtp_from: str = "no-reply@smart-traffic.local"

    @field_validator("jwt_secret")
    @classmethod
    def _strong_secret(cls, v: SecretStr) -> SecretStr:
        raw = v.get_secret_value()
        if len(raw) < 32 or "CHANGE_ME" in raw:
            raise ValueError("JWT_SECRET must be at least 32 random characters, not the placeholder.")
        return v

    @model_validator(mode="after")
    def _production_guards(self) -> "Settings":
        if self.environment == "production":
            if not self.smtp_host:
                raise ValueError("SMTP_HOST is required in production so reset links never go to logs.")
            if "*" in self.cors_origins:
                raise ValueError("CORS_ORIGINS must not contain '*' in production.")
        return self


@lru_cache
def get_settings() -> Settings:
    return Settings()  # type: ignore[call-arg]
