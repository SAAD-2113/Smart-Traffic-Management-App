"""Engine input types. Everything is plain data so any source can produce it."""
from dataclasses import dataclass, field
from datetime import datetime
from enum import StrEnum

from traffic_engine.geo import bearing_deg


class Source(StrEnum):
    MOBILE = "MOBILE"          # participating smartphones (a sample of all traffic)
    SIMULATOR = "SIMULATOR"    # built-in demo fleet (observes its whole simulated world)
    SUMO = "SUMO"              # SUMO via TraCI (observes its whole simulated world)
    CAMERA = "CAMERA"          # detector counts per approach
    SENSOR = "SENSOR"          # other roadside detectors

    @property
    def observes_all_vehicles(self) -> bool:
        """Simulators see every vehicle; phones are only a sample (see penetration rate)."""
        return self in (Source.SIMULATOR, Source.SUMO)


class Zone(StrEnum):
    CORE = "CORE"            # inside the junction box
    APPROACH = "APPROACH"    # within the approach radius, moving towards the centre
    DEPARTURE = "DEPARTURE"  # within the approach radius, moving away
    ON_LINK = "ON_LINK"      # between intersections, on a configured link


class CongestionLevel(StrEnum):
    UNKNOWN = "UNKNOWN"
    LOW = "LOW"
    MODERATE = "MODERATE"
    HIGH = "HIGH"
    SEVERE = "SEVERE"

    @property
    def rank(self) -> int:
        return _CONGESTION_RANK[self]


_CONGESTION_RANK = {
    CongestionLevel.UNKNOWN: -1,
    CongestionLevel.LOW: 0,
    CongestionLevel.MODERATE: 1,
    CongestionLevel.HIGH: 2,
    CongestionLevel.SEVERE: 3,
}


class DataQuality(StrEnum):
    NONE = "NONE"
    LOW = "LOW"
    MEDIUM = "MEDIUM"
    HIGH = "HIGH"


@dataclass(frozen=True)
class Observation:
    """One vehicle position at one instant, from any source."""

    key: str                      # stable per vehicle within its source, e.g. "veh:<uuid>", "sumo:flow1.3"
    source: Source
    lat: float
    lon: float
    recorded_at: datetime
    accuracy_m: float = 5.0
    speed_mps: float | None = None
    heading_deg: float | None = None
    emergency: bool = False
    vehicle_type: str = "NORMAL"
    label: str | None = None      # display label (vehicle code); never personal data


@dataclass(frozen=True)
class DetectorCount:
    """A direct count from a camera or loop detector. Not scaled by penetration rate."""

    intersection_code: str
    approach_name: str
    vehicle_count: int
    observed_at: datetime
    source: Source = Source.CAMERA
    queue_length_m: float | None = None


@dataclass(frozen=True)
class ApproachGeometry:
    name: str
    travel_bearing_deg: float          # direction vehicles travel while approaching
    bearing_tolerance_deg: float = 45.0
    lanes: int = 1
    zone_length_m: float = 200.0
    free_flow_speed_mps: float = 11.1
    upstream_code: str | None = None


@dataclass(frozen=True)
class IntersectionGeometry:
    code: str
    name: str
    lat: float
    lon: float
    radius_m: float
    approach_radius_m: float
    penetration_rate: float = 0.05
    approaches: tuple[ApproachGeometry, ...] = ()
    active: bool = True
    ref: str | None = None             # caller's id (e.g. database UUID), carried through untouched

    def approach(self, name: str | None) -> ApproachGeometry | None:
        return next((a for a in self.approaches if a.name == name), None)

    @property
    def lane_km(self) -> float:
        """Road length covered by the approach zones, in lane-kilometres."""
        total = sum(a.zone_length_m * a.lanes for a in self.approaches)
        if total <= 0:  # no approaches configured: assume four single-lane legs
            total = 4 * (self.approach_radius_m - self.radius_m)
        return total / 1000.0

    @property
    def mean_free_flow_mps(self) -> float:
        if not self.approaches:
            return 11.1
        return sum(a.free_flow_speed_mps for a in self.approaches) / len(self.approaches)


@dataclass(frozen=True)
class LinkGeometry:
    """Directed road segment from one intersection to the next."""

    id: str
    from_code: str
    to_code: str
    distance_m: float
    free_flow_speed_mps: float = 11.1
    to_approach_name: str | None = None


@dataclass
class Network:
    intersections: dict[str, IntersectionGeometry]
    links: list[LinkGeometry] = field(default_factory=list)

    def active(self) -> list[IntersectionGeometry]:
        return [i for i in self.intersections.values() if i.active]

    def incoming(self, code: str) -> list[LinkGeometry]:
        return [link for link in self.links if link.to_code == code]

    def outgoing(self, code: str) -> list[LinkGeometry]:
        return [link for link in self.links if link.from_code == code]

    def link_bearing(self, link: LinkGeometry) -> float:
        a, b = self.intersections[link.from_code], self.intersections[link.to_code]
        return bearing_deg(a.lat, a.lon, b.lat, b.lon)

    def valid_links(self) -> list[LinkGeometry]:
        return [
            link for link in self.links
            if link.from_code in self.intersections and link.to_code in self.intersections
        ]
