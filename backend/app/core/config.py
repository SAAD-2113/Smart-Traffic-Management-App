from functools import lru_cache
from typing import Literal

from pydantic import Field, SecretStr, field_validator, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict
from sqlalchemy.engine import make_url
from traffic_engine import CongestionLevel, DataQuality
from traffic_engine.control import ModeThresholds


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
    simulated_telemetry_retention_hours: int = Field(default=1, ge=1, le=24 * 365)

    # Fixed-time / adaptive switching for AUTO intersections (traffic_engine/control/modes.py).
    # Congestion is averaged over control_window_s; see docs/ARCHITECTURE.md "Signal-control modes".
    control_enter_level: Literal["MODERATE", "HIGH", "SEVERE"] = "HIGH"
    control_exit_level: Literal["LOW", "MODERATE", "HIGH"] = "LOW"
    control_window_s: float = Field(default=60.0, ge=10, le=600)
    control_enter_hold_s: float = Field(default=20.0, ge=0, le=600)
    control_exit_hold_s: float = Field(default=60.0, ge=0, le=1800)
    control_min_adaptive_s: float = Field(default=120.0, ge=0, le=3600)
    control_min_data_quality: Literal["LOW", "MEDIUM", "HIGH"] = "MEDIUM"
    control_min_vehicles: float = Field(default=8.0, ge=0, le=500)

    # Demo simulation (never enable on a production deployment)
    demo_default_vehicles: int = Field(default=30, ge=1, le=200)
    demo_max_vehicles: int = Field(default=80, ge=1, le=500)

    password_reset_url: str = "http://localhost:8080/reset-password"
    smtp_host: str | None = None
    smtp_port: int = 587
    smtp_username: str | None = None
    smtp_password: SecretStr | None = None
    smtp_from: str = "no-reply@smart-traffic.local"

    @field_validator("database_url")
    @classmethod
    def _async_driver(cls, v: str) -> str:
        """Accept the plain postgres:// URLs that hosting providers hand out.

        The app needs the asyncpg driver, and asyncpg takes `ssl=` instead of libpq's `sslmode=`.
        """
        url = make_url(v)
        if url.drivername in ("postgres", "postgresql"):
            url = url.set(drivername="postgresql+asyncpg")
        if url.drivername == "postgresql+asyncpg":
            query = dict(url.query)
            sslmode = query.pop("sslmode", None)
            query.pop("channel_binding", None)  # libpq-only option
            if sslmode and "ssl" not in query:
                query["ssl"] = sslmode
            url = url.set(query=query)
        return url.render_as_string(hide_password=False)

    @field_validator("jwt_secret")
    @classmethod
    def _strong_secret(cls, v: SecretStr) -> SecretStr:
        raw = v.get_secret_value()
        if len(raw) < 32 or "CHANGE_ME" in raw:
            raise ValueError("JWT_SECRET must be at least 32 random characters, not the placeholder.")
        return v

    def mode_thresholds(self) -> ModeThresholds:
        return ModeThresholds(
            enter_level=CongestionLevel(self.control_enter_level),
            exit_level=CongestionLevel(self.control_exit_level),
            window_s=self.control_window_s,
            enter_hold_s=self.control_enter_hold_s,
            exit_hold_s=self.control_exit_hold_s,
            min_adaptive_s=self.control_min_adaptive_s,
            min_data_quality=DataQuality(self.control_min_data_quality),
            min_vehicles=self.control_min_vehicles,
        )

    @model_validator(mode="after")
    def _control_thresholds(self) -> "Settings":
        errors = self.mode_thresholds().validate()
        if errors:
            raise ValueError("Signal control settings: " + " ".join(errors))
        return self

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
