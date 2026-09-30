"""Converts engine state into API models (the engine itself knows nothing about the API)."""
from datetime import datetime

from traffic_engine import ApproachMetrics, IntersectionMetrics, IntersectionState, ObservedStats

from app.schemas.traffic import (
    ApproachTrafficOut,
    CalculatedOut,
    DownstreamOut,
    EmergencyNearOut,
    EstimatedOut,
    IntersectionTrafficOut,
    ObservedOut,
    SignalDecisionOut,
    SignalStateOut,
    UpstreamOut,
)
from app.services.network_cache import IntersectionInfo


def _r(value: float | None, digits: int = 2) -> float | None:
    return None if value is None else round(value, digits)


def observed_out(stats: ObservedStats) -> ObservedOut:
    return ObservedOut(
        vehicle_count=stats.vehicle_count, stopped_count=stats.stopped_count,
        emergency_count=stats.emergency_count, speed_sample_count=stats.speed_sample_count,
        avg_speed_mps=_r(stats.avg_speed_mps), min_speed_mps=_r(stats.min_speed_mps),
        max_speed_mps=_r(stats.max_speed_mps),
    )


def approach_out(a: ApproachMetrics, penetration: float) -> ApproachTrafficOut:
    return ApproachTrafficOut(
        name=a.approach_name,
        observed=observed_out(a.observed),
        calculated=CalculatedOut(
            speed_ratio=_r(a.speed_ratio, 3), avg_waiting_time_s=_r(a.avg_waiting_time_s, 1),
            expected_arrivals_60s=a.expected_arrivals_60s,
        ),
        estimated=EstimatedOut(
            vehicle_count=_r(a.estimated_vehicle_count, 1),
            density_veh_per_km_lane=_r(a.density_veh_per_km_lane, 1),
            penetration_rate=penetration,
        ),
        congestion_level=a.congestion_level.value,
        data_quality=a.data_quality.value,
        detector_count=a.detector_count,
        max_waiting_time_s=_r(a.max_waiting_time_s, 1),
    )


def _empty_metrics(code: str) -> IntersectionMetrics:
    from traffic_engine.model import CongestionLevel, DataQuality

    return IntersectionMetrics(
        code=code, observed=ObservedStats(), core_count=0, departure_count=0, speed_ratio=None,
        avg_waiting_time_s=None, estimated_vehicle_count=None, density_veh_per_km_lane=None,
        congestion_level=CongestionLevel.UNKNOWN, data_quality=DataQuality.NONE,
    )


def intersection_out(
    info: IntersectionInfo,
    state: IntersectionState | None,
    *,
    signal: SignalStateOut | None,
    connected: bool,
    decision: SignalDecisionOut | None,
    computed_at: datetime | None,
) -> IntersectionTrafficOut:
    m = state.metrics if state else _empty_metrics(info.code)
    arrivals = sum(a.expected_arrivals_60s for a in m.approaches)
    return IntersectionTrafficOut(
        id=info.id, code=info.code, name=info.name, latitude=info.latitude, longitude=info.longitude,
        radius_m=info.radius_m, approach_radius_m=info.approach_radius_m, status=info.status,
        controller_type=info.controller_type, actuator=info.actuator,
        congestion_level=m.congestion_level.value, data_quality=m.data_quality.value,
        fully_observed=m.fully_observed, sources=m.sources,
        observed=observed_out(m.observed),
        calculated=CalculatedOut(
            speed_ratio=_r(m.speed_ratio, 3), avg_waiting_time_s=_r(m.avg_waiting_time_s, 1),
            expected_arrivals_60s=arrivals,
        ),
        estimated=EstimatedOut(
            vehicle_count=_r(m.estimated_vehicle_count, 1),
            density_veh_per_km_lane=_r(m.density_veh_per_km_lane, 1),
            penetration_rate=info.penetration_rate,
        ),
        core_count=m.core_count,
        departure_count=m.departure_count,
        approaches=[approach_out(a, info.penetration_rate) for a in m.approaches],
        upstream=[
            UpstreamOut(from_code=u.from_code, to_approach_name=u.to_approach_name,
                        vehicles_on_link=u.vehicles_on_link, expected_arrivals_60s=u.expected_arrivals_60s,
                        estimated_arrivals_60s=round(u.estimated_arrivals_60s, 1),
                        avg_speed_mps=_r(u.avg_speed_mps))
            for u in (state.upstream if state else [])
        ],
        downstream=[
            DownstreamOut(to_code=d.to_code, congestion_level=d.congestion_level.value,
                          data_quality=d.data_quality.value)
            for d in (state.downstream if state else [])
        ],
        emergencies=[
            EmergencyNearOut(label=e.label, vehicle_type=e.vehicle_type, approach_name=e.approach_name,
                             zone=e.zone.value, distance_m=round(e.distance_m, 1), eta_s=_r(e.eta_s, 1),
                             source=e.source)
            for e in (state.emergencies if state else [])
        ],
        signal=signal,
        connected=connected,
        decision=decision,
        computed_at=computed_at,
    )
