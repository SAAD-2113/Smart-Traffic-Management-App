"""Importing this package registers every table on Base.metadata (needed by Alembic and tests)."""
from app.models.intersection import Intersection, IntersectionApproach, IntersectionLink
from app.models.system import AuditLog, ControllerClient, controller_client_scopes
from app.models.user import PasswordResetToken, RefreshToken, User
from app.models.vehicle import CodeCounter, Device, EmergencyAuthorization, Vehicle

__all__ = [
    "AuditLog",
    "CodeCounter",
    "ControllerClient",
    "Device",
    "EmergencyAuthorization",
    "Intersection",
    "IntersectionApproach",
    "IntersectionLink",
    "PasswordResetToken",
    "RefreshToken",
    "User",
    "Vehicle",
    "controller_client_scopes",
]
