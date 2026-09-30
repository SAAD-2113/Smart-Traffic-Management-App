"""Turn mapped observations into approach- and intersection-level metrics.

Every metric is labelled by how it was obtained:
- observed:   counted or measured directly from vehicles in the zone
- calculated: derived deterministically from observed values (ratios, stop durations)
- estimated:  depends on an assumption, mainly the share of vehicles that report (penetration)
"""
from collections.abc import Iterable
from dataclasses import dataclass, field
from datetime import datetime

from traffic_engine.mapping import MappedObservation
from traffic_engine.model import (
    CongestionLevel,
    DataQuality,
    DetectorCount,
    IntersectionGeometry,
    Network,
    Zone,
)

STOPPED_SPEED_MPS = 1.5
DETECTOR_MAX_AGE_S = 30.0
STOP_TRACKER_TTL_S = 30.0

# Speed ratio (observed speed / free-flow speed) thresholds, most congested last.
SPEED_RATIO_CLASSES = ((0.7, CongestionLevel.LOW), (0.4, CongestionLevel.MODERATE), (0.2, CongestionLevel.HIGH))
# Density thresholds in vehicles per km per lane.
DENSITY_CLASSES = ((15.0, CongestionLevel.LOW), (30.0, CongestionLevel.MODERATE), (50.0, CongestionLevel.HIGH))


@dataclass
class ObservedStats:
    vehicle_count: int = 0
    stopped_count: int = 0
    emergency_count: int = 0
    speed_sample_count: int = 0
    avg_speed_mps: float | None = None
    min_speed_mps: float | None = None
    max_speed_mps: float | None = None


@dataclass
class ApproachMetrics:
    approach_name: str
    observed: ObservedStats
    speed_ratio: float | None                 # calculated
    avg_waiting_time_s: float | None          # calculated (stopped time so far, a lower bound)
    max_waiting_time_s: float | None          # calculated
    estimated_vehicle_count: float | None     # estimated
    density_veh_per_km_lane: float | None     # estimated
    congestion_level: CongestionLevel
    data_quality: DataQuality
    detector_count: int | None = None         # observed, from a camera/sensor
    expected_arrivals_60s: int = 0            # filled in by network state (observed)
    estimated_arrivals_60s: float = 0.0       # filled in by network state (estimated)


@dataclass
class IntersectionMetrics:
    code: str
    observed: ObservedStats
    core_count: int
    departure_count: int
    speed_ratio: float | None
    avg_waiting_time_s: float | None
    estimated_vehicle_count: float | None
    density_veh_per_km_lane: float | None
    congestion_level: CongestionLevel
    data_quality: DataQuality
    approaches: list[ApproachMetrics] = field(default_factory=list)
    unassigned_approach_count: int = 0
    sources: list[str] = field(default_factory=list)
    fully_observed: bool = False


class StopTracker:
    """Remembers since when each vehicle has been stopped in an approach, across cycles."""

    def __init__(self) -> None:
        self._stopped_since: dict[str, tuple[str, datetime]] = {}  # key -> (approach id, since)
        self._last_seen: dict[str, datetime] = {}

    def update(self, key: str, approach_id: str | None, stopped: bool, now: datetime) -> float | None:
        self._last_seen[key] = now
        if not stopped or approach_id is None:
            self._stopped_since.pop(key, None)
            return None
        current = self._stopped_since.get(key)
        if current is None or current[0] != approach_id:
            self._stopped_since[key] = (approach_id, now)
            return 0.0
        return (now - current[1]).total_seconds()

    def expire(self, now: datetime) -> None:
        stale = [k for k, seen in self._last_seen.items() if (now - seen).total_seconds() > STOP_TRACKER_TTL_S]
        for key in stale:
            self._last_seen.pop(key, None)
            self._stopped_since.pop(key, None)

    def __len__(self) -> int:
        return len(self._stopped_since)


def data_quality(vehicle_count: int, fully_observed: bool) -> DataQuality:
    if fully_observed:
        return DataQuality.HIGH
    if vehicle_count == 0:
        return DataQuality.NONE
    if vehicle_count <= 2:
        return DataQuality.LOW
    if vehicle_count <= 9:
        return DataQuality.MEDIUM
    return DataQuality.HIGH


def classify_congestion(
    speed_ratio: float | None, density: float | None, quality: DataQuality, vehicle_count: int
) -> CongestionLevel:
    """The worse of the speed-based and density-based classes.

    The density class relies on the penetration-rate scaling, which is too noisy with one or
    two probe vehicles, so it is only used from MEDIUM data quality upwards.
    """
    if quality == DataQuality.NONE:
        return CongestionLevel.UNKNOWN
    if vehicle_count == 0:
        return CongestionLevel.LOW  # fully observed and empty
    levels: list[CongestionLevel] = []
    if speed_ratio is not None:
        levels.append(_classify(speed_ratio, SPEED_RATIO_CLASSES, higher_is_better=True))
    if density is not None and quality in (DataQuality.MEDIUM, DataQuality.HIGH):
        levels.append(_classify(density, DENSITY_CLASSES, higher_is_better=False))
    if not levels:
        return CongestionLevel.UNKNOWN
    return max(levels, key=lambda level: level.rank)


def _classify(value: float, classes, *, higher_is_better: bool) -> CongestionLevel:
    for threshold, level in classes:
        if (value >= threshold) if higher_is_better else (value < threshold):
            return level
    return CongestionLevel.SEVERE


def _stats(items: list[MappedObservation]) -> ObservedStats:
    speeds = [m.observation.speed_mps for m in items if m.observation.speed_mps is not None]
    return ObservedStats(
        vehicle_count=len(items),
        stopped_count=sum(1 for s in speeds if s < STOPPED_SPEED_MPS),
        emergency_count=sum(1 for m in items if m.observation.emergency),
        speed_sample_count=len(speeds),
        avg_speed_mps=sum(speeds) / len(speeds) if speeds else None,
        min_speed_mps=min(speeds) if speeds else None,
        max_speed_mps=max(speeds) if speeds else None,
    )


def _estimated_count(items: Iterable[MappedObservation], node: IntersectionGeometry) -> float:
    """Scale each observation by the share of vehicles its source can see."""
    total = 0.0
    for m in items:
        rate = 1.0 if m.observation.source.observes_all_vehicles else node.penetration_rate
        total += 1.0 / rate
    return total


def aggregate(
    mapped: list[MappedObservation],
    network: Network,
    now: datetime,
    stop_tracker: StopTracker,
    detector_counts: Iterable[DetectorCount] = (),
    fully_observed_codes: frozenset[str] | set[str] = frozenset(),
) -> dict[str, IntersectionMetrics]:
    detectors: dict[tuple[str, str], DetectorCount] = {}
    for count in detector_counts:
        if (now - count.observed_at).total_seconds() <= DETECTOR_MAX_AGE_S:
            detectors[(count.intersection_code, count.approach_name)] = count

    by_node: dict[str, list[MappedObservation]] = {}
    for m in mapped:
        if m.intersection_code is not None and m.zone in (Zone.CORE, Zone.APPROACH, Zone.DEPARTURE):
            by_node.setdefault(m.intersection_code, []).append(m)

    results: dict[str, IntersectionMetrics] = {}
    for node in network.active():
        items = by_node.get(node.code, [])
        fully_observed = node.code in fully_observed_codes
        inbound = [m for m in items if m.zone in (Zone.CORE, Zone.APPROACH)]

        approaches: list[ApproachMetrics] = []
        waits: list[float] = []
        for approach in node.approaches:
            group = [m for m in inbound if m.zone == Zone.APPROACH and m.approach_name == approach.name]
            stats = _stats(group)
            approach_waits = []
            for m in group:
                speed = m.observation.speed_mps
                wait = stop_tracker.update(
                    m.key, f"{node.code}/{approach.name}", speed is not None and speed < STOPPED_SPEED_MPS, now
                )
                if wait is not None:
                    approach_waits.append(wait)
            waits.extend(approach_waits)

            estimated = _estimated_count(group, node)
            detector = detectors.get((node.code, approach.name))
            if detector is not None:
                estimated = max(estimated, float(detector.vehicle_count))
            count_for_quality = stats.vehicle_count + (detector.vehicle_count if detector else 0)
            quality = data_quality(count_for_quality, fully_observed or detector is not None)
            density = estimated / (approach.zone_length_m * approach.lanes / 1000.0)
            ratio = (
                stats.avg_speed_mps / approach.free_flow_speed_mps if stats.avg_speed_mps is not None else None
            )
            approaches.append(
                ApproachMetrics(
                    approach_name=approach.name,
                    observed=stats,
                    speed_ratio=ratio,
                    avg_waiting_time_s=sum(approach_waits) / len(approach_waits) if approach_waits else None,
                    max_waiting_time_s=max(approach_waits) if approach_waits else None,
                    estimated_vehicle_count=estimated if quality != DataQuality.NONE else None,
                    density_veh_per_km_lane=density if quality != DataQuality.NONE else None,
                    congestion_level=classify_congestion(
                        ratio, density, quality, max(stats.vehicle_count, detector.vehicle_count if detector else 0)
                    ),
                    data_quality=quality,
                    detector_count=detector.vehicle_count if detector else None,
                )
            )

        stats = _stats(inbound)
        detector_total = sum(a.detector_count or 0 for a in approaches)
        estimated = max(_estimated_count(inbound, node), float(detector_total))
        quality = data_quality(stats.vehicle_count + detector_total, fully_observed or detector_total > 0)
        density = estimated / node.lane_km
        ratio = stats.avg_speed_mps / node.mean_free_flow_mps if stats.avg_speed_mps is not None else None
        results[node.code] = IntersectionMetrics(
            code=node.code,
            observed=stats,
            core_count=sum(1 for m in inbound if m.zone == Zone.CORE),
            departure_count=sum(1 for m in items if m.zone == Zone.DEPARTURE),
            speed_ratio=ratio,
            avg_waiting_time_s=sum(waits) / len(waits) if waits else None,
            estimated_vehicle_count=estimated if quality != DataQuality.NONE else None,
            density_veh_per_km_lane=density if quality != DataQuality.NONE else None,
            congestion_level=classify_congestion(ratio, density, quality, max(stats.vehicle_count, detector_total)),
            data_quality=quality,
            approaches=approaches,
            unassigned_approach_count=sum(1 for m in inbound if m.zone == Zone.APPROACH and m.approach_name is None),
            sources=sorted({m.observation.source.value for m in items}),
            fully_observed=fully_observed,
        )

    # Anything not queued in a known approach (in the junction, departing, between junctions)
    # is no longer waiting.
    for m in mapped:
        if not (m.zone == Zone.APPROACH and m.approach_name is not None):
            stop_tracker.update(m.key, None, False, now)
    stop_tracker.expire(now)
    return results


__all__ = [
    "ApproachMetrics",
    "IntersectionMetrics",
    "ObservedStats",
    "StopTracker",
    "aggregate",
    "classify_congestion",
    "data_quality",
]
