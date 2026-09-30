"""Demo fleet: simulated vehicles driving over the configured intersection network.

Built for demonstrations and tests when real vehicles are unavailable. Vehicles follow
routes through the intersection graph, use the Intelligent Driver Model (IDM) for car
following, and stop for virtual signals, so signal decisions visibly change queues.
Every observation it produces is tagged Source.SIMULATOR.
"""
import math
import random
from dataclasses import dataclass, field
from datetime import datetime

from traffic_engine.geo import angle_diff_deg, bearing_deg, destination, haversine_m, interpolate
from traffic_engine.model import IntersectionGeometry, Network, Observation, Source
from traffic_engine.simulation.signals import LightState, VirtualSignal

ENTRY_LEAD_IN_M = 150.0
EXIT_LENGTH_M = 300.0
VEHICLE_LENGTH_M = 4.5
MAX_ROUTE_NODES = 6
TURN_PROBABILITY = 0.2

# IDM parameters (typical urban values)
IDM_ACCEL = 1.5
IDM_DECEL = 2.5
IDM_MIN_GAP = 2.0
IDM_HEADWAY_S = 1.2
MAX_BRAKE = 8.0

EMERGENCY_FIRST_TRIP_S = 45.0
EMERGENCY_TRIP_INTERVAL_S = 240.0
DEMAND_WAVE_PERIOD_S = 180.0
DEMAND_WAVE_LENGTH_S = 60.0


@dataclass(frozen=True)
class VehicleSpec:
    key: str
    label: str
    vehicle_type: str = "NORMAL"

    @property
    def is_emergency_type(self) -> bool:
        return self.vehicle_type != "NORMAL"


@dataclass
class _Stop:
    s: float                  # stop-line position along the route (m)
    node_code: str
    approach_name: str | None


@dataclass
class _Route:
    points: list[tuple[float, float]]
    cum: list[float]
    seg_keys: list[str]
    stops: list[_Stop]
    speeds: list[float]       # desired free-flow speed per segment

    @property
    def length(self) -> float:
        return self.cum[-1]

    def segment_at(self, s: float) -> int:
        for i in range(len(self.cum) - 1):
            if s < self.cum[i + 1]:
                return i
        return len(self.cum) - 2

    def position(self, s: float) -> tuple[float, float, float]:
        i = self.segment_at(s)
        (lat1, lon1), (lat2, lon2) = self.points[i], self.points[i + 1]
        seg = self.cum[i + 1] - self.cum[i]
        t = 0.0 if seg <= 0 else (s - self.cum[i]) / seg
        lat, lon = interpolate(lat1, lon1, lat2, lon2, max(0.0, min(1.0, t)))
        return lat, lon, bearing_deg(lat1, lon1, lat2, lon2)


@dataclass
class _Entry:
    node: IntersectionGeometry
    bearing: float            # travel direction when entering the node
    approach_name: str
    point: tuple[float, float]
    corridor: bool            # continues onto a link (main road) rather than a side street


@dataclass
class SimVehicle:
    spec: VehicleSpec
    rng_speed_factor: float
    route: _Route | None = None
    s: float = 0.0
    v: float = 0.0
    respawn_at: float = 0.0
    emergency_active: bool = False

    @property
    def active(self) -> bool:
        return self.route is not None


@dataclass
class FleetEvent:
    kind: str                 # "EMERGENCY_STARTED" / "EMERGENCY_ENDED" / "TRIP_STARTED" / "TRIP_ENDED"
    vehicle_key: str


@dataclass
class DemoFleet:
    network: Network
    specs: list[VehicleSpec]
    seed: int = 7
    target_active_share: float = 0.8
    clock_s: float = 0.0
    vehicles: list[SimVehicle] = field(init=False)
    _rng: random.Random = field(init=False)
    _entries: list[_Entry] = field(init=False)
    _pending_events: list[FleetEvent] = field(init=False, default_factory=list)

    def __post_init__(self) -> None:
        self._rng = random.Random(self.seed)
        self._entries = self._build_entries()
        self.vehicles = []
        for i, spec in enumerate(self.specs):
            vehicle = SimVehicle(spec=spec, rng_speed_factor=self._rng.uniform(0.85, 1.1))
            if spec.is_emergency_type:
                vehicle.respawn_at = EMERGENCY_FIRST_TRIP_S
            else:
                vehicle.respawn_at = self._rng.uniform(0.0, 20.0) + i * 0.5
            self.vehicles.append(vehicle)

    # -- network geometry ----------------------------------------------------------
    def _build_entries(self) -> list[_Entry]:
        entries: list[_Entry] = []
        fed_by_links = {(link.to_code, link.to_approach_name) for link in self.network.valid_links()}
        for node in self.network.active():
            for approach in node.approaches:
                if approach.upstream_code is not None or (node.code, approach.name) in fed_by_links:
                    continue
                start = destination(
                    node.lat, node.lon, (approach.travel_bearing_deg + 180.0) % 360.0,
                    approach.zone_length_m + ENTRY_LEAD_IN_M,
                )
                corridor = self._next_link(node, approach.travel_bearing_deg) is not None
                entries.append(_Entry(node, approach.travel_bearing_deg, approach.name, start, corridor))
        return entries

    def _next_link(self, node: IntersectionGeometry, direction: float):
        best, best_diff = None, 31.0
        for link in self.network.outgoing(node.code):
            if link.to_code not in self.network.intersections or not self.network.intersections[link.to_code].active:
                continue
            diff = angle_diff_deg(self.network.link_bearing(link), direction)
            if diff < best_diff:
                best, best_diff = link, diff
        return best

    @staticmethod
    def _approach_for(node: IntersectionGeometry, direction: float) -> str | None:
        best, best_diff = None, 181.0
        for a in node.approaches:
            diff = angle_diff_deg(a.travel_bearing_deg, direction)
            if diff <= a.bearing_tolerance_deg and diff < best_diff:
                best, best_diff = a.name, diff
        return best

    def _leg_directions(self, node: IntersectionGeometry) -> list[float]:
        return [(a.travel_bearing_deg + 180.0) % 360.0 for a in node.approaches]

    def _build_route(self, entry: _Entry, allow_turns: bool) -> _Route:
        points = [entry.point]
        node, direction = entry.node, entry.bearing
        stop_nodes: list[tuple[IntersectionGeometry, str | None]] = []
        speeds: list[float] = []
        approach_geo = node.approach(entry.approach_name)
        speeds.append(approach_geo.free_flow_speed_mps if approach_geo else 11.1)

        for _ in range(MAX_ROUTE_NODES):
            stop_nodes.append((node, self._approach_for(node, bearing_deg(*points[-1], node.lat, node.lon))))
            points.append((node.lat, node.lon))
            if allow_turns and self._rng.random() < TURN_PROBABILITY:
                options = [
                    d for d in self._leg_directions(node)
                    if 30.0 < angle_diff_deg(d, direction) < 150.0
                ]
                if options:
                    direction = self._rng.choice(options)
            link = self._next_link(node, direction)
            if link is None:
                points.append(destination(node.lat, node.lon, direction, EXIT_LENGTH_M))
                speeds.append(11.1)
                break
            speeds.append(link.free_flow_speed_mps)
            nxt = self.network.intersections[link.to_code]
            direction = bearing_deg(node.lat, node.lon, nxt.lat, nxt.lon)
            node = nxt
        else:
            points.append(destination(node.lat, node.lon, direction, EXIT_LENGTH_M))
            speeds.append(11.1)

        cum = [0.0]
        for (a_lat, a_lon), (b_lat, b_lon) in zip(points, points[1:]):
            cum.append(cum[-1] + haversine_m(a_lat, a_lon, b_lat, b_lon))
        seg_keys = [
            f"{a[0]:.5f},{a[1]:.5f}>{b[0]:.5f},{b[1]:.5f}" for a, b in zip(points, points[1:])
        ]
        stops = [
            _Stop(s=cum[i + 1] - node.radius_m, node_code=node.code, approach_name=approach)
            for i, (node, approach) in enumerate(stop_nodes)
        ]
        return _Route(points=points, cum=cum, seg_keys=seg_keys, stops=stops, speeds=speeds[: len(points) - 1])

    # -- simulation ----------------------------------------------------------------
    def _entry_weights(self) -> list[float]:
        wave = (self.clock_s % DEMAND_WAVE_PERIOD_S) < DEMAND_WAVE_LENGTH_S
        corridor_entries = [e for e in self._entries if e.corridor]
        wave_entry = min(corridor_entries, key=lambda e: e.point[1]) if corridor_entries else None
        weights = []
        for e in self._entries:
            w = 3.0 if e.corridor else 1.0
            if wave and e is wave_entry:
                w *= 4.0
            weights.append(w)
        return weights

    def _spawn(self, vehicle: SimVehicle) -> bool:
        if not self._entries:
            return False
        if vehicle.spec.is_emergency_type:
            corridor = [e for e in self._entries if e.corridor] or self._entries
            entry = min(corridor, key=lambda e: e.point[1])  # westernmost main-road entry
            route = self._build_route(entry, allow_turns=False)
        else:
            entry = self._rng.choices(self._entries, weights=self._entry_weights())[0]
            route = self._build_route(entry, allow_turns=True)
        # Do not spawn on top of a vehicle that has not left the entry yet.
        for other in self.vehicles:
            if other.active and other.route.seg_keys[0] == route.seg_keys[0] and other.s < 15.0:
                return False
        vehicle.route, vehicle.s = route, 0.0
        vehicle.v = route.speeds[0] * 0.6
        self._pending_events.append(FleetEvent("TRIP_STARTED", vehicle.spec.key))
        if vehicle.spec.is_emergency_type:
            vehicle.emergency_active = True
            self._pending_events.append(FleetEvent("EMERGENCY_STARTED", vehicle.spec.key))
        return True

    def _finish(self, vehicle: SimVehicle) -> None:
        vehicle.route = None
        vehicle.v = 0.0
        self._pending_events.append(FleetEvent("TRIP_ENDED", vehicle.spec.key))
        if vehicle.emergency_active:
            vehicle.emergency_active = False
            self._pending_events.append(FleetEvent("EMERGENCY_ENDED", vehicle.spec.key))
            vehicle.respawn_at = self.clock_s + EMERGENCY_TRIP_INTERVAL_S
        else:
            active = sum(1 for v in self.vehicles if v.active)
            wanted = self.target_active_share * sum(1 for v in self.vehicles if not v.spec.is_emergency_type)
            mean_wait = 5.0 if active < wanted else 40.0
            vehicle.respawn_at = self.clock_s + self._rng.expovariate(1.0 / mean_wait)

    def _leader_gap(self, vehicle: SimVehicle, positions: dict[str, list[tuple[float, SimVehicle]]]):
        route = vehicle.route
        i = route.segment_at(vehicle.s)
        offset = vehicle.s - route.cum[i]
        best_gap, best_speed = None, 0.0
        for other_offset, other in positions.get(route.seg_keys[i], []):
            if other is vehicle or other_offset <= offset:
                continue
            gap = other_offset - offset - VEHICLE_LENGTH_M
            if best_gap is None or gap < best_gap:
                best_gap, best_speed = gap, other.v
        if best_gap is None and i + 1 < len(route.seg_keys):
            remaining = route.cum[i + 1] - vehicle.s
            for other_offset, other in positions.get(route.seg_keys[i + 1], []):
                gap = remaining + other_offset - VEHICLE_LENGTH_M
                if best_gap is None or gap < best_gap:
                    best_gap, best_speed = gap, other.v
        return best_gap, best_speed

    def _signal_gap(self, vehicle: SimVehicle, signals: dict[str, VirtualSignal]) -> float | None:
        for stop in vehicle.route.stops:
            gap = stop.s - vehicle.s
            if gap < -0.5:
                continue  # already past this stop line
            signal = signals.get(stop.node_code)
            if signal is None:
                return None
            light = signal.light_for(stop.approach_name)
            if light == LightState.GREEN:
                return None
            if light == LightState.YELLOW and vehicle.v ** 2 / (2 * IDM_DECEL) > gap:
                return None  # too close to stop comfortably: proceed on yellow
            return max(gap, 0.01)
        return None

    def step(self, dt: float, now: datetime, signals: dict[str, VirtualSignal]) -> None:
        self.clock_s += dt
        for vehicle in self.vehicles:
            if not vehicle.active and self.clock_s >= vehicle.respawn_at:
                if not self._spawn(vehicle):
                    vehicle.respawn_at = self.clock_s + 1.0

        positions: dict[str, list[tuple[float, SimVehicle]]] = {}
        for vehicle in self.vehicles:
            if vehicle.active:
                i = vehicle.route.segment_at(vehicle.s)
                positions.setdefault(vehicle.route.seg_keys[i], []).append((vehicle.s - vehicle.route.cum[i], vehicle))

        for vehicle in self.vehicles:
            if not vehicle.active:
                continue
            route = vehicle.route
            seg = route.segment_at(vehicle.s)
            v0 = route.speeds[min(seg, len(route.speeds) - 1)] * vehicle.rng_speed_factor
            if vehicle.emergency_active:
                v0 *= 1.25
            gap, leader_speed = self._leader_gap(vehicle, positions)
            signal_gap = self._signal_gap(vehicle, signals)
            if signal_gap is not None and (gap is None or signal_gap < gap):
                gap, leader_speed = signal_gap, 0.0
            vehicle.v, vehicle.s = _idm_step(vehicle.v, vehicle.s, v0, gap, leader_speed, dt)
            if vehicle.s >= route.length:
                self._finish(vehicle)

    def drain_events(self) -> list[FleetEvent]:
        events, self._pending_events = self._pending_events, []
        return events

    def observations(self, now: datetime, gps_noise_m: float = 2.5) -> list[Observation]:
        result = []
        for vehicle in self.vehicles:
            if not vehicle.active:
                continue
            lat, lon, heading = vehicle.route.position(vehicle.s)
            noise_n, noise_e = self._rng.gauss(0, gps_noise_m), self._rng.gauss(0, gps_noise_m)
            lat += noise_n / 111_320.0
            lon += noise_e / (111_320.0 * math.cos(math.radians(lat)))
            speed = max(0.0, vehicle.v + self._rng.gauss(0, 0.2))
            result.append(
                Observation(
                    key=vehicle.spec.key,
                    source=Source.SIMULATOR,
                    lat=lat,
                    lon=lon,
                    recorded_at=now,
                    accuracy_m=round(self._rng.uniform(3.0, 8.0), 1),
                    speed_mps=round(speed, 2),
                    heading_deg=round(heading, 1) if speed >= 0.5 else None,
                    emergency=vehicle.emergency_active,
                    vehicle_type=vehicle.spec.vehicle_type,
                    label=vehicle.spec.label,
                )
            )
        return result

    @property
    def active_count(self) -> int:
        return sum(1 for v in self.vehicles if v.active)


def _idm_step(v: float, s: float, v0: float, gap: float | None, leader_speed: float, dt: float) -> tuple[float, float]:
    free = 1.0 - (v / max(v0, 0.1)) ** 4
    interaction = 0.0
    if gap is not None:
        dv = v - leader_speed
        s_star = IDM_MIN_GAP + max(0.0, v * IDM_HEADWAY_S + v * dv / (2.0 * math.sqrt(IDM_ACCEL * IDM_DECEL)))
        interaction = (s_star / max(gap, 0.1)) ** 2
    accel = max(-MAX_BRAKE, IDM_ACCEL * (free - interaction))
    v_new = max(0.0, v + accel * dt)
    s_new = s + (v + v_new) / 2.0 * dt
    if gap is not None:
        # Never drive through the obstacle in front, whatever the discretisation says.
        s_new = min(s_new, s + max(0.0, gap - 0.05))
        if s_new == s:
            v_new = 0.0
    return v_new, s_new
