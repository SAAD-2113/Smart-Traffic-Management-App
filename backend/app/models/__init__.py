"""Importing this package registers every table on Base.metadata (needed by Alembic and tests)."""
from app.models.emergency import EmergencyEvent
from app.models.intersection import Intersection, IntersectionApproach, IntersectionLink
from app.models.system import AuditLog, ControllerClient, controller_client_scopes
from app.models.telemetry import TrackingSession, VehicleLiveState, VehicleTelemetry
from app.models.traffic import (
    SignalDecisionRecord,
    SignalModeEvent,
    SignalPlanConfig,
    SignalStateRecord,
    TrafficMetric,
)
from app.models.user import PasswordResetToken, RefreshToken, User
from app.models.vehicle import CodeCounter, Device, EmergencyAuthorization, Vehicle

__all__ = [
    "AuditLog",
    "CodeCounter",
    "ControllerClient",
    "Device",
    "EmergencyAuthorization",
    "EmergencyEvent",
    "Intersection",
    "IntersectionApproach",
    "IntersectionLink",
    "PasswordResetToken",
    "RefreshToken",
    "SignalDecisionRecord",
    "SignalModeEvent",
    "SignalPlanConfig",
    "SignalStateRecord",
    "TrackingSession",
    "TrafficMetric",
    "User",
    "Vehicle",
    "VehicleLiveState",
    "VehicleTelemetry",
    "controller_client_scopes",
]
