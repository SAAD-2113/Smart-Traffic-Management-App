"""Network-wide traffic state: each intersection plus its upstream and downstream context."""
from dataclasses import dataclass, field
from datetime import datetime

from traffic_engine.aggregation import IntersectionMetrics
from traffic_engine.mapping import MappedObservation
from traffic_engine.model import CongestionLevel, DataQuality, Network, Zone

ARRIVAL_HORIZON_S = 60.0
EMERGENCY_HORIZON_S = 120.0


@dataclass
class UpstreamFlow:
    link_id: str
    from_code: str
    to_approach_name: str | None
    vehicles_on_link: int                 # observed
    expected_arrivals_60s: int            # observed (ETA within the horizon)
    estimated_arrivals_60s: float         # estimated (scaled by penetration)
    avg_speed_mps: float | None           # observed


@dataclass
class DownstreamLoad:
    link_id: str
    to_code: str
    bearing_deg: float
    congestion_level: CongestionLevel
    data_quality: DataQuality


@dataclass
class EmergencyApproach:
    vehicle_key: str
    label: str | None
    vehicle_type: str
    approach_name: str | None
    zone: Zone
    distance_m: float
    eta_s: float | None
    source: str


@dataclass
class IntersectionState:
    code: str
    name: str
    metrics: IntersectionMetrics
    upstream: list[UpstreamFlow] = field(default_factory=list)
    downstream: list[DownstreamLoad] = field(default_factory=list)
    emergencies: list[EmergencyApproach] = field(default_factory=list)


@dataclass
class NetworkState:
    timestamp: datetime
    intersections: dict[str, IntersectionState]

    def congested_codes(self) -> list[str]:
        return [
            code for code, s in self.intersections.items()
            if s.metrics.congestion_level in (CongestionLevel.HIGH, CongestionLevel.SEVERE)
        ]


def build_network_state(
    network: Network,
    metrics: dict[str, IntersectionMetrics],
    mapped: list[MappedObservation],
    now: datetime,
) -> NetworkState:
    states: dict[str, IntersectionState] = {}
    on_link: dict[str, list[MappedObservation]] = {}
    for m in mapped:
        if m.link_id is not None:
            on_link.setdefault(m.link_id, []).append(m)

    for node in network.active():
        node_metrics = metrics.get(node.code)
        if node_metrics is None:
            continue
        state = IntersectionState(code=node.code, name=node.name, metrics=node_metrics)

        for link in network.incoming(node.code):
            if link.from_code not in network.intersections:
                continue
            vehicles = on_link.get(link.id, [])
            arriving = [m for m in vehicles if m.eta_s is not None and m.eta_s <= ARRIVAL_HORIZON_S]
            speeds = [m.observation.speed_mps for m in vehicles if m.observation.speed_mps is not None]
            estimated = sum(
                1.0 if m.observation.source.observes_all_vehicles else 1.0 / node.penetration_rate
                for m in arriving
            )
            state.upstream.append(
                UpstreamFlow(
                    link_id=link.id,
                    from_code=link.from_code,
                    to_approach_name=link.to_approach_name,
                    vehicles_on_link=len(vehicles),
                    expected_arrivals_60s=len(arriving),
                    estimated_arrivals_60s=estimated,
                    avg_speed_mps=sum(speeds) / len(speeds) if speeds else None,
                )
            )
            approach = next(
                (a for a in node_metrics.approaches if a.approach_name == link.to_approach_name), None
            )
            if approach is not None:
                approach.expected_arrivals_60s += len(arriving)
                approach.estimated_arrivals_60s += estimated

        for m in mapped:
            obs = m.observation
            if not obs.emergency:
                continue
            if m.intersection_code == node.code and m.zone in (Zone.APPROACH, Zone.CORE):
                distance, approach, eta = m.distance_to_centre_m or 0.0, m.approach_name, m.eta_s
            elif m.link_to_code == node.code and m.eta_s is not None and m.eta_s <= EMERGENCY_HORIZON_S:
                distance, approach, eta = m.distance_to_next_m or 0.0, m.link_to_approach, m.eta_s
            else:
                continue
            state.emergencies.append(
                EmergencyApproach(
                    vehicle_key=obs.key, label=obs.label, vehicle_type=obs.vehicle_type,
                    approach_name=approach, zone=m.zone if m.intersection_code == node.code else Zone.ON_LINK,
                    distance_m=distance, eta_s=eta, source=obs.source.value,
                )
            )
        state.emergencies.sort(key=lambda e: e.eta_s if e.eta_s is not None else 1e9)
        states[node.code] = state

    for node in network.active():
        if node.code not in states:
            continue
        for link in network.outgoing(node.code):
            downstream = states.get(link.to_code)
            if downstream is None:
                continue
            states[node.code].downstream.append(
                DownstreamLoad(
                    link_id=link.id,
                    to_code=link.to_code,
                    bearing_deg=network.link_bearing(link),
                    congestion_level=downstream.metrics.congestion_level,
                    data_quality=downstream.metrics.data_quality,
                )
            )

    return NetworkState(timestamp=now, intersections=states)
