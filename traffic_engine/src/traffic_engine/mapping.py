"""Vehicle-to-intersection mapping: which junction, which zone, which approach, which link."""
from dataclasses import dataclass

from traffic_engine.geo import angle_diff_deg, bearing_deg, haversine_m, point_to_segment, to_local_xy
from traffic_engine.model import IntersectionGeometry, LinkGeometry, Network, Observation, Zone

# Below this speed a GNSS heading is noise; the bearing to the junction centre is used instead.
MIN_SPEED_FOR_HEADING_MPS = 1.0
# A vehicle is "moving towards" the centre if its direction is within this angle of the centre.
TOWARDS_CENTRE_MAX_DEG = 90.0
LINK_CORRIDOR_M = 40.0
LINK_DIRECTION_TOLERANCE_DEG = 60.0
MIN_ETA_SPEED_MPS = 3.0


@dataclass(frozen=True)
class MappedObservation:
    observation: Observation
    intersection_code: str | None = None
    zone: Zone | None = None
    approach_name: str | None = None
    distance_to_centre_m: float | None = None
    link_id: str | None = None
    link_to_code: str | None = None
    link_to_approach: str | None = None
    distance_to_next_m: float | None = None   # along the link to the next intersection centre
    eta_s: float | None = None                # to the next intersection centre

    @property
    def key(self) -> str:
        return self.observation.key


def travel_direction(obs: Observation) -> float | None:
    """The vehicle's direction of travel, or None when it is (nearly) stationary."""
    if obs.heading_deg is None:
        return None
    if obs.speed_mps is not None and obs.speed_mps < MIN_SPEED_FOR_HEADING_MPS:
        return None
    return obs.heading_deg % 360.0


def _eta(distance_m: float, speed_mps: float | None, fallback_speed_mps: float) -> float:
    speed = speed_mps if speed_mps is not None else fallback_speed_mps
    return distance_m / max(speed, MIN_ETA_SPEED_MPS)


def _nearest_intersection(obs: Observation, network: Network) -> tuple[IntersectionGeometry, float] | None:
    best: tuple[IntersectionGeometry, float] | None = None
    for node in network.active():
        d = haversine_m(obs.lat, obs.lon, node.lat, node.lon)
        if d <= node.approach_radius_m and (best is None or d < best[1]):
            best = (node, d)
    return best


def _match_approach(node: IntersectionGeometry, direction: float) -> str | None:
    best_name, best_diff = None, 181.0
    for approach in node.approaches:
        diff = angle_diff_deg(direction, approach.travel_bearing_deg)
        if diff <= approach.bearing_tolerance_deg and diff < best_diff:
            best_name, best_diff = approach.name, diff
    return best_name


def _match_link(obs: Observation, network: Network) -> tuple[LinkGeometry, float] | None:
    """Link the vehicle is travelling along, and the remaining distance to its end."""
    direction = travel_direction(obs)
    if direction is None:
        return None  # a stationary vehicle on a two-way road cannot be given a direction
    best: tuple[LinkGeometry, float, float] | None = None  # link, lateral offset, remaining m
    for link in network.valid_links():
        a, b = network.intersections[link.from_code], network.intersections[link.to_code]
        if not (a.active and b.active):
            continue
        if angle_diff_deg(direction, network.link_bearing(link)) > LINK_DIRECTION_TOLERANCE_DEG:
            continue
        px, py = to_local_xy(obs.lat, obs.lon, a.lat, a.lon)
        bx, by = to_local_xy(b.lat, b.lon, a.lat, a.lon)
        lateral, t = point_to_segment(px, py, 0.0, 0.0, bx, by)
        if lateral > LINK_CORRIDOR_M + min(obs.accuracy_m, 50.0):
            continue
        remaining = (1.0 - t) * link.distance_m
        if best is None or lateral < best[1]:
            best = (link, lateral, remaining)
    return (best[0], best[2]) if best else None


def map_observation(obs: Observation, network: Network) -> MappedObservation:
    nearest = _nearest_intersection(obs, network)
    if nearest is not None:
        node, distance = nearest
        if distance <= node.radius_m:
            return MappedObservation(obs, node.code, Zone.CORE, None, distance, eta_s=0.0)

        to_centre = bearing_deg(obs.lat, obs.lon, node.lat, node.lon)
        direction = travel_direction(obs)
        towards = direction is None or angle_diff_deg(direction, to_centre) <= TOWARDS_CENTRE_MAX_DEG
        if towards:
            # Stationary vehicles inside an approach zone are queued on the road that leads in,
            # so the bearing to the centre stands in for their direction of travel.
            approach = _match_approach(node, direction if direction is not None else to_centre)
            geometry = node.approach(approach)
            fallback = geometry.free_flow_speed_mps if geometry else node.mean_free_flow_mps
            eta = _eta(distance, obs.speed_mps, fallback)
            return MappedObservation(obs, node.code, Zone.APPROACH, approach, distance, eta_s=eta)

        mapped = MappedObservation(obs, node.code, Zone.DEPARTURE, None, distance)
        link = _match_link(obs, network)
        if link is None:
            return mapped
        return _with_link(mapped, *link)

    link = _match_link(obs, network)
    if link is None:
        return MappedObservation(obs)
    return _with_link(MappedObservation(obs, zone=Zone.ON_LINK), *link)


def _with_link(mapped: MappedObservation, link: LinkGeometry, remaining_m: float) -> MappedObservation:
    return MappedObservation(
        observation=mapped.observation,
        intersection_code=mapped.intersection_code,
        zone=mapped.zone,
        approach_name=mapped.approach_name,
        distance_to_centre_m=mapped.distance_to_centre_m,
        link_id=link.id,
        link_to_code=link.to_code,
        link_to_approach=link.to_approach_name,
        distance_to_next_m=remaining_m,
        eta_s=_eta(remaining_m, mapped.observation.speed_mps, link.free_flow_speed_mps),
    )
