"""Converts engine state into API models (the engine itself knows nothing about the API)."""
from datetime import datetime

from traffic_engine import ApproachMetrics, IntersectionGeometry, IntersectionMetrics, IntersectionState, ObservedStats
from traffic_engine.control import ControlStatus, PhaseTiming, SignalPlan, TrafficSnapshot

from app.schemas.traffic import (
    ApproachTrafficOut,
    CalculatedOut,
    ControlStatusOut,
    DownstreamOut,
    EmergencyNearOut,
    EstimatedOut,
    IntersectionTrafficOut,
    ObservedOut,
    PendingSwitchOut,
    PhaseTimingOut,
    SignalDecisionOut,
    SignalDisplayOut,
    SignalHeadOut,
    SignalStateOut,
    TrafficBasisOut,
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


def basis_out(t: TrafficSnapshot) -> TrafficBasisOut:
    return TrafficBasisOut(
        congestion_level=t.congestion_level.value,
        averaged_level=t.averaged_level.value if t.averaged_level else None,
        averaged_rank=t.averaged_rank, data_quality=t.data_quality.value, vehicle_count=t.vehicle_count,
        estimated_vehicle_count=t.estimated_vehicle_count, avg_speed_mps=t.avg_speed_mps,
        avg_waiting_time_s=t.avg_waiting_time_s, window_s=t.window_s, window_vehicle_count=t.window_vehicle_count,
        window_estimated_vehicles=t.window_estimated_vehicles, window_avg_speed_mps=t.window_avg_speed_mps,
        window_avg_waiting_time_s=t.window_avg_waiting_time_s, worst_approach=t.worst_approach,
        worst_approach_level=t.worst_approach_level.value if t.worst_approach_level else None,
        worst_approach_vehicles=t.worst_approach_vehicles,
    )


def _timings_out(timings: tuple[PhaseTiming, ...]) -> list[PhaseTimingOut]:
    return [
        PhaseTimingOut(phase=t.phase, approaches=list(t.approaches), green_s=t.green_s, yellow_s=t.yellow_s,
                       all_red_s=t.all_red_s, red_s=t.red_s)
        for t in timings
    ]


def control_out(c: ControlStatus) -> ControlStatusOut:
    return ControlStatusOut(
        policy=c.policy.value, mode=c.mode.value, base_mode=c.base_mode.value, reason=c.reason.value,
        headline=c.headline, detail=c.detail, since=c.since,
        pending=PendingSwitchOut(to_mode=c.pending.to_mode.value, in_s=round(c.pending.in_s, 1),
                                 condition=c.pending.condition) if c.pending else None,
        traffic=basis_out(c.traffic),
        fixed_timing=_timings_out(c.fixed_timing), fixed_cycle_s=c.fixed_cycle_s,
        active_timing=_timings_out(c.active_timing), active_cycle_s=c.active_cycle_s,
        algorithm=c.algorithm.value if c.algorithm else None, priority_phase=c.priority_phase,
    )


_HEAD_LIGHT = {"GREEN": "GREEN", "YELLOW": "YELLOW", "ALL_RED": "RED", "FLASHING": "YELLOW", "OFF": "OFF"}


def display_out(state: SignalStateOut, *, virtual: bool, plan: SignalPlan, node: IntersectionGeometry) -> SignalDisplayOut:
    """Per-approach lights from the current phase: its approaches show the phase colour, others red."""
    light_state = state.state.value if hasattr(state.state, "value") else str(state.state)
    heads = []
    for approach in sorted(node.approaches, key=lambda a: a.travel_bearing_deg):
        phase = plan.phase_for_approach(approach.name)
        if phase is None or light_state == "OFF":
            light = "OFF"
        elif phase.name == state.phase_name:
            light = _HEAD_LIGHT.get(light_state, "RED")
        else:
            light = "YELLOW" if light_state == "FLASHING" else "RED"
        heads.append(SignalHeadOut(approach=approach.name, bearing_deg=approach.travel_bearing_deg, light=light))
    mode = state.mode.value if hasattr(state.mode, "value") else str(state.mode)
    return SignalDisplayOut(
        source=state.source, virtual=virtual, phase_name=state.phase_name, state=light_state,
        remaining_s=state.remaining_s, mode=mode, reported_at=state.reported_at, heads=heads,
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
    control: ControlStatusOut | None = None,
    display_signal: SignalDisplayOut | None = None,
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
        control=control,
        display_signal=display_signal,
    )
