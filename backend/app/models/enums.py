from enum import StrEnum


class UserRole(StrEnum):
    END_USER = "END_USER"
    MANAGER = "MANAGER"
    ADMIN = "ADMIN"  # created only from the CLI; manages manager accounts and controller keys


class VehicleType(StrEnum):
    NORMAL = "NORMAL"
    AMBULANCE = "AMBULANCE"
    FIRE_TRUCK = "FIRE_TRUCK"
    POLICE = "POLICE"

    @property
    def is_emergency(self) -> bool:
        return self is not VehicleType.NORMAL


class VehicleStatus(StrEnum):
    ACTIVE = "ACTIVE"
    SUSPENDED = "SUSPENDED"  # excluded from the data pipeline by a manager
    RETIRED = "RETIRED"


class AuthorizationStatus(StrEnum):
    PENDING = "PENDING"
    APPROVED = "APPROVED"
    REJECTED = "REJECTED"
    REVOKED = "REVOKED"


class DeviceStatus(StrEnum):
    ACTIVE = "ACTIVE"
    INACTIVE = "INACTIVE"


class DevicePlatform(StrEnum):
    ANDROID = "ANDROID"
    IOS = "IOS"


class IntersectionStatus(StrEnum):
    ACTIVE = "ACTIVE"
    INACTIVE = "INACTIVE"
    MAINTENANCE = "MAINTENANCE"


class ControllerType(StrEnum):
    FIXED = "FIXED"
    ADAPTIVE = "ADAPTIVE"


class ActuatorType(StrEnum):
    SUMO = "SUMO"
    HARDWARE = "HARDWARE"
    DISPLAY_ONLY = "DISPLAY_ONLY"


class ControllerClientKind(StrEnum):
    RASPBERRY_PI = "RASPBERRY_PI"
    SUMO_BRIDGE = "SUMO_BRIDGE"
    CAMERA = "CAMERA"
    OTHER = "OTHER"
