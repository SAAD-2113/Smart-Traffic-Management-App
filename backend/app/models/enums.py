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


class TelemetrySource(StrEnum):
    MOBILE = "MOBILE"
    SIMULATOR = "SIMULATOR"


class SpeedSource(StrEnum):
    GPS = "GPS"
    DERIVED = "DERIVED"  # computed on the phone from consecutive fixes


class GpsQuality(StrEnum):
    EXCELLENT = "EXCELLENT"  # <= 10 m
    GOOD = "GOOD"            # <= 25 m
    FAIR = "FAIR"            # <= 50 m
    POOR = "POOR"            # > 50 m: stored, not used for traffic metrics

    @classmethod
    def from_accuracy(cls, accuracy_m: float) -> "GpsQuality":
        if accuracy_m <= 10:
            return cls.EXCELLENT
        if accuracy_m <= 25:
            return cls.GOOD
        if accuracy_m <= 50:
            return cls.FAIR
        return cls.POOR


class TrafficZone(StrEnum):
    CORE = "CORE"
    APPROACH = "APPROACH"
    DEPARTURE = "DEPARTURE"
    ON_LINK = "ON_LINK"


class SessionEndReason(StrEnum):
    USER = "USER"
    RESTARTED = "RESTARTED"
    TIMEOUT = "TIMEOUT"
    VEHICLE_SUSPENDED = "VEHICLE_SUSPENDED"
    DEMO_STOPPED = "DEMO_STOPPED"


class TrackingStatus(StrEnum):
    """Derived for display; not stored."""

    TRANSMITTING = "TRANSMITTING"  # open session, live fix within the live window
    STALE = "STALE"                # open session, no recent fix
    NOT_TRACKING = "NOT_TRACKING"


class EmergencyEventStatus(StrEnum):
    ACTIVE = "ACTIVE"
    ENDED = "ENDED"


class EmergencyEndReason(StrEnum):
    DRIVER = "DRIVER"
    MANAGER = "MANAGER"
    TIMEOUT = "TIMEOUT"
    AUTH_REVOKED = "AUTH_REVOKED"
    TRACKING_STOPPED = "TRACKING_STOPPED"
    VEHICLE_SUSPENDED = "VEHICLE_SUSPENDED"
    DEMO_STOPPED = "DEMO_STOPPED"


class LightState(StrEnum):
    GREEN = "GREEN"
    YELLOW = "YELLOW"
    ALL_RED = "ALL_RED"
    FLASHING = "FLASHING"
    OFF = "OFF"


class SignalMode(StrEnum):
    FIXED_LOCAL = "FIXED_LOCAL"
    ADAPTIVE = "ADAPTIVE"
    EMERGENCY = "EMERGENCY"
    FLASHING = "FLASHING"
    OFF = "OFF"
