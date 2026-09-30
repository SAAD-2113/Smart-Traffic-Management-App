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

    # Telemetry validation (see docs/ARCHITECTURE.md, "Telemetry packet specification")
    live_window_s: float = Field(default=15.0, ge=5, le=60)
    backfill_max_age_s: float = Field(default=600.0, ge=60, le=3600)
    future_tolerance_s: float = Field(default=30.0, ge=1, le=300)
    usable_accuracy_m: float = Field(default=50.0, gt=0, le=200)
    max_accuracy_m: float = Field(default=500.0, gt=0, le=5000)
    max_speed_mps: float = Field(default=70.0, gt=0, le=150)
    max_jump_speed_mps: float = Field(default=80.0, gt=0, le=300)
    min_packet_interval_s: float = Field(default=0.5, ge=0, le=10)
    telemetry_batch_max: int = Field(default=100, ge=1, le=500)
    session_idle_timeout_s: float = Field(default=600.0, ge=60, le=86400)

    # Emergency vehicles
    emergency_stale_s: float = Field(default=120.0, ge=15, le=3600)
    emergency_max_duration_s: float = Field(default=3600.0, ge=300, le=6 * 3600)
    emergency_start_max_fix_age_s: float = Field(default=30.0, ge=5, le=600)

    # Traffic engine runner
    traffic_engine_enabled: bool = True
    traffic_cycle_s: float = Field(default=2.0, ge=0.5, le=60)
    metrics_persist_interval_s: float = Field(default=30.0, ge=5, le=3600)
    telemetry_retention_days: int = Field(default=30, ge=1, le=3650)
    simulated_telemetry_retention_hours: int = Field(default=24, ge=1, le=24 * 365)

    # Demo simulation (never enable on a production deployment)
    demo_default_vehicles: int = Field(default=30, ge=1, le=200)
    demo_max_vehicles: int = Field(default=80, ge=1, le=500)

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
            if self.demo_mode:
                raise ValueError("DEMO_MODE must be false in production.")
        return self


@lru_cache
def get_settings() -> Settings:
    return Settings()  # type: ignore[call-arg]
