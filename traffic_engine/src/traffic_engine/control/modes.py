"""Fixed-time / adaptive mode switching: the traffic-control state machine.

    traffic data -> congestion, averaged over a window -+- normal ----> FIXED_TIME
                                                         +- congested -> ADAPTIVE
    An emergency vehicle about to arrive overrides either mode (EMERGENCY_PRIORITY).

Rules for the AUTO policy (all thresholds come from ModeThresholds, i.e. configuration):

- FIXED_TIME -> ADAPTIVE when the averaged congestion is at or above `enter_level` for
  `enter_hold_s` seconds (data quality at least `min_data_quality`).
- ADAPTIVE -> FIXED_TIME when the averaged congestion is at or below `exit_level` for
  `exit_hold_s` seconds and the intersection has been adaptive for `min_adaptive_s`.
  Congestion between the two levels keeps the current mode (hysteresis).
- ADAPTIVE -> FIXED_TIME at once when there is not enough data to judge congestion:
  adaptive timing needs traffic data, and the fixed plan is the safe default.

Congestion is averaged because a single engine cycle sees vehicles queued at a red light
as congestion; a window of about one signal cycle separates real congestion from normal
red-light queues. The FIXED and ADAPTIVE policies are manual overrides that skip the rules.

Prototype status: transparent rules for demonstration and simulation, not a certified
signal controller. Decisions remain advisory (see controllers.py).
"""
from collections import deque
from dataclasses import dataclass, field
from datetime import datetime
from enum import StrEnum

from traffic_engine.control.controllers import (
    EmergencyPriorityController,
    FixedTimeController,
    SignalController,
    adaptive_controller,
)
from traffic_engine.control.plan import Algorithm, SignalDecision, SignalPlan
from traffic_engine.model import CongestionLevel, DataQuality, IntersectionGeometry
from traffic_engine.network import IntersectionState, NetworkState

_QUALITY_RANK = {DataQuality.NONE: 0, DataQuality.LOW: 1, DataQuality.MEDIUM: 2, DataQuality.HIGH: 3}
_LEVELS = (CongestionLevel.LOW, CongestionLevel.MODERATE, CongestionLevel.HIGH, CongestionLevel.SEVERE)
MIN_VALID_SAMPLES = 2


class ControlPolicy(StrEnum):
    """What a manager configured for an intersection."""

    AUTO = "AUTO"            # fixed-time while traffic is normal, adaptive while congested
    FIXED = "FIXED"          # always the fixed-time plan
    ADAPTIVE = "ADAPTIVE"    # always adaptive timing


class ControlMode(StrEnum):
    """What the intersection is doing right now."""

    FIXED_TIME = "FIXED_TIME"
    ADAPTIVE = "ADAPTIVE"
    EMERGENCY_PRIORITY = "EMERGENCY_PRIORITY"


class ModeReason(StrEnum):
    NORMAL_TRAFFIC = "NORMAL_TRAFFIC"
    CONGESTION_DETECTED = "CONGESTION_DETECTED"    # congested, waiting out enter_hold_s
    HIGH_CONGESTION = "HIGH_CONGESTION"
    SEVERE_CONGESTION = "SEVERE_CONGESTION"
    CONGESTION_EASING = "CONGESTION_EASING"        # normal again, waiting out exit_hold_s
    CONGESTION_CLEARED = "CONGESTION_CLEARED"      # just returned to fixed-time
    INSUFFICIENT_DATA = "INSUFFICIENT_DATA"
    MANUAL_FIXED = "MANUAL_FIXED"
    MANUAL_ADAPTIVE = "MANUAL_ADAPTIVE"
    EMERGENCY_VEHICLE = "EMERGENCY_VEHICLE"


def level_for_rank(rank: float) -> CongestionLevel:
    """Averaged rank back to a level: <0.5 LOW, <1.5 MODERATE, <2.5 HIGH, otherwise SEVERE."""
    return _LEVELS[min(3, max(0, int(rank + 0.5)))]


@dataclass(frozen=True)
class ModeThresholds:
    enter_level: CongestionLevel = CongestionLevel.HIGH
    exit_level: CongestionLevel = CongestionLevel.LOW
    window_s: float = 60.0
    enter_hold_s: float = 20.0
    exit_hold_s: float = 60.0
    min_adaptive_s: float = 120.0
    min_data_quality: DataQuality = DataQuality.MEDIUM
    min_vehicles: float = 8.0      # average (estimated) vehicles needed before congestion counts

    def validate(self) -> list[str]:
        errors = []
        if self.enter_level not in _LEVELS or self.exit_level not in _LEVELS:
            errors.append("Congestion levels must be LOW, MODERATE, HIGH or SEVERE.")
        elif self.exit_level.rank >= self.enter_level.rank:
            errors.append("The exit level must be lower than the enter level.")
        if self.min_data_quality == DataQuality.NONE:
            errors.append("The minimum data quality must be at least LOW.")
        for name in ("window_s", "enter_hold_s", "exit_hold_s", "min_adaptive_s"):
            if getattr(self, name) < 0:
                errors.append(f"{name} cannot be negative.")
        if self.window_s <= 0:
            errors.append("window_s must be positive.")
        if self.min_vehicles < 0:
            errors.append("min_vehicles cannot be negative.")
        return errors


@dataclass(frozen=True)
class PhaseTiming:
    """One phase of a timing plan. red_s is the rest of the cycle (including all-red)."""

    phase: str
    approaches: tuple[str, ...]
    green_s: float
    yellow_s: float
    all_red_s: float
    red_s: float


def phase_timings(plan: SignalPlan, greens: dict[str, float]) -> tuple[tuple[PhaseTiming, ...], float]:
    cycle = sum(greens.get(p.name, p.fixed_green_s) + p.clearance_s for p in plan.phases)
    timings = tuple(
        PhaseTiming(
            phase=p.name, approaches=p.approaches, green_s=round(greens.get(p.name, p.fixed_green_s), 1),
            yellow_s=p.yellow_s, all_red_s=p.all_red_s,
            red_s=round(cycle - greens.get(p.name, p.fixed_green_s) - p.yellow_s, 1),
        )
        for p in plan.phases
    )
    return timings, round(cycle, 1)


@dataclass(frozen=True)
class TrafficSnapshot:
    """The traffic figures a mode decision was based on (SI units)."""

    congestion_level: CongestionLevel          # this cycle
    averaged_level: CongestionLevel | None     # over the window; None = not enough data
    averaged_rank: float | None
    data_quality: DataQuality
    vehicle_count: int                         # observed now, in the approach zones and the junction
    estimated_vehicle_count: float | None
    avg_speed_mps: float | None
    avg_waiting_time_s: float | None
    window_s: float                            # the averaging window behind the window_* figures
    window_vehicle_count: float | None         # mean over the window (what the mode decision used)
    window_estimated_vehicles: float | None
    window_avg_speed_mps: float | None
    window_avg_waiting_time_s: float | None
    worst_approach: str | None
    worst_approach_level: CongestionLevel | None
    worst_approach_vehicles: int


@dataclass(frozen=True)
class PendingSwitch:
    to_mode: ControlMode
    in_s: float
    condition: str


@dataclass(frozen=True)
class ControlStatus:
    code: str
    policy: ControlPolicy
    mode: ControlMode                  # effective mode, including emergency priority
    base_mode: ControlMode             # FIXED_TIME or ADAPTIVE from the rules above
    reason: ModeReason
    headline: str
    detail: str
    since: datetime                    # when the current effective mode began
    pending: PendingSwitch | None
    traffic: TrafficSnapshot
    fixed_timing: tuple[PhaseTiming, ...]
    fixed_cycle_s: float
    active_timing: tuple[PhaseTiming, ...]
    active_cycle_s: float
    algorithm: Algorithm | None        # of the decision behind active_timing; None = local fixed plan
    priority_phase: str | None


@dataclass(frozen=True)
class ModeChange:
    code: str
    at: datetime
    from_mode: ControlMode
    to_mode: ControlMode
    reason: ModeReason
    headline: str
    detail: str
    traffic: TrafficSnapshot


@dataclass
class _Track:
    base_mode: ControlMode
    base_since: datetime
    effective: ControlMode
    effective_since: datetime
    policy: ControlPolicy
    candidate_since: datetime | None = None
    samples: deque = field(default_factory=deque)   # _Sample per engine cycle within the window


@dataclass(frozen=True)
class _Sample:
    at: datetime
    rank: int | None          # None = no usable congestion level this cycle
    vehicles: int
    estimated: float          # scaled for probe sources; equals vehicles when fully observed
    speed_mps: float | None
    wait_s: float | None


def _kmh(speed_mps: float | None) -> str:
    return "unknown" if speed_mps is None else f"{speed_mps * 3.6:.0f} km/h"


def _vehicles(n: int) -> str:
    return f"{n} vehicle" + ("" if n == 1 else "s")


class ModeController:
    """Keeps the mode of every intersection across engine cycles (one per engine)."""

    def __init__(
        self,
        thresholds: ModeThresholds | None = None,
        *,
        fixed: SignalController | None = None,
        adaptive: SignalController | None = None,
    ) -> None:
        self.thresholds = thresholds or ModeThresholds()
        errors = self.thresholds.validate()
        if errors:
            raise ValueError("; ".join(errors))
        self.fixed = fixed or EmergencyPriorityController(FixedTimeController())
        self.adaptive = adaptive or adaptive_controller()
        self._tracks: dict[str, _Track] = {}

    def prune(self, codes: set[str]) -> None:
        for code in list(self._tracks):
            if code not in codes:
                del self._tracks[code]

    # -- traffic figures ---------------------------------------------------------------
    def _sample(self, track: _Track, state: IntersectionState, now: datetime) -> float | None:
        m = state.metrics
        valid = (
            m.congestion_level != CongestionLevel.UNKNOWN
            and _QUALITY_RANK[m.data_quality] >= _QUALITY_RANK[self.thresholds.min_data_quality]
        )
        estimated = m.estimated_vehicle_count if m.estimated_vehicle_count is not None else m.observed.vehicle_count
        track.samples.append(_Sample(now, m.congestion_level.rank if valid else None, m.observed.vehicle_count,
                                     float(estimated), m.observed.avg_speed_mps, m.avg_waiting_time_s))
        while track.samples and (now - track.samples[0].at).total_seconds() > self.thresholds.window_s:
            track.samples.popleft()
        ranks = [s.rank for s in track.samples if s.rank is not None]
        if len(ranks) < max(MIN_VALID_SAMPLES, len(track.samples) / 2):
            return None
        return sum(ranks) / len(ranks)

    def _snapshot(self, track: _Track, state: IntersectionState, averaged: float | None) -> TrafficSnapshot:
        m = state.metrics

        def mean(values: list[float]) -> float | None:
            return round(sum(values) / len(values), 2) if values else None

        samples = list(track.samples)
        worst = max(
            (a for a in m.approaches if a.congestion_level != CongestionLevel.UNKNOWN),
            key=lambda a: (a.congestion_level.rank, a.observed.vehicle_count),
            default=None,
        )
        return TrafficSnapshot(
            congestion_level=m.congestion_level,
            averaged_level=level_for_rank(averaged) if averaged is not None else None,
            averaged_rank=round(averaged, 2) if averaged is not None else None,
            data_quality=m.data_quality,
            vehicle_count=m.observed.vehicle_count,
            estimated_vehicle_count=round(m.estimated_vehicle_count, 1) if m.estimated_vehicle_count is not None else None,
            avg_speed_mps=round(m.observed.avg_speed_mps, 2) if m.observed.avg_speed_mps is not None else None,
            avg_waiting_time_s=round(m.avg_waiting_time_s, 1) if m.avg_waiting_time_s is not None else None,
            worst_approach=worst.approach_name if worst else None,
            worst_approach_level=worst.congestion_level if worst else None,
            worst_approach_vehicles=worst.observed.vehicle_count if worst else 0,
            window_s=self.thresholds.window_s,
            window_vehicle_count=mean([float(s.vehicles) for s in samples]),
            window_estimated_vehicles=mean([s.estimated for s in samples]),
            window_avg_speed_mps=mean([s.speed_mps for s in samples if s.speed_mps is not None]),
            window_avg_waiting_time_s=mean([s.wait_s for s in samples if s.wait_s is not None]),
        )

    # -- explanations ----------------------------------------------------------------
    def _explain(self, reason: ModeReason, t: TrafficSnapshot, pending: PendingSwitch | None) -> tuple[str, str]:
        th = self.thresholds
        window = f"{th.window_s:.0f} s"
        avg = t.averaged_level.value if t.averaged_level else "unknown"
        vehicles = t.window_vehicle_count if t.window_vehicle_count is not None else t.vehicle_count
        figures = (f"on average {vehicles:.0f} vehicles at {_kmh(t.window_avg_speed_mps)} over the last {window}"
                   if t.window_vehicle_count is not None else f"{_vehicles(t.vehicle_count)}, {_kmh(t.avg_speed_mps)}")
        if t.worst_approach and t.worst_approach_level in (CongestionLevel.HIGH, CongestionLevel.SEVERE):
            figures += (f"; worst approach {t.worst_approach} ({t.worst_approach_level.value}, "
                        f"{_vehicles(t.worst_approach_vehicles)})")
        match reason:
            case ModeReason.NORMAL_TRAFFIC:
                return "Normal traffic", (f"Average congestion over the last {window} is {avg} ({figures}); "
                                          "the fixed-time plan is running.")
            case ModeReason.CONGESTION_DETECTED:
                return "Congestion building", (
                    f"Average congestion is {avg} ({figures}); switching to adaptive timing in "
                    f"{pending.in_s:.0f} s if it persists." if pending else f"Average congestion is {avg}.")
            case ModeReason.HIGH_CONGESTION | ModeReason.SEVERE_CONGESTION:
                head = "Severe congestion detected" if reason == ModeReason.SEVERE_CONGESTION else "High congestion detected"
                return head, f"{figures}. Green times are calculated from current demand instead of the fixed plan."
            case ModeReason.CONGESTION_EASING:
                return "Congestion easing", (
                    f"Average congestion is {avg} ({figures}); returning to the fixed-time plan in "
                    f"{pending.in_s:.0f} s if traffic stays normal." if pending else
                    f"Average congestion is {avg} ({figures}); adaptive timing continues until it is "
                    f"{th.exit_level.value} or lower for {th.exit_hold_s:.0f} s.")
            case ModeReason.CONGESTION_CLEARED:
                return "Congestion cleared", (f"Traffic has been normal for {th.exit_hold_s:.0f} s (average "
                                              f"congestion {avg}, {figures}); back to the fixed-time plan.")
            case ModeReason.INSUFFICIENT_DATA:
                return "Not enough traffic data", (
                    f"Data quality {t.data_quality.value} ({_vehicles(t.vehicle_count)} reporting) is not enough to "
                    f"judge congestion (needs {th.min_data_quality.value}); the fixed-time plan is the safe default.")
            case ModeReason.MANUAL_FIXED:
                return "Fixed-time selected", "A manager set this intersection to fixed-time control."
            case ModeReason.MANUAL_ADAPTIVE:
                return "Adaptive selected", f"A manager set this intersection to adaptive control at all times ({figures})."
        return reason.value, ""

    def _emergency_text(self, state: IntersectionState, decision: SignalDecision) -> tuple[str, str]:
        e = next((e for e in state.emergencies if e.eta_s is not None), None)
        if e is None:
            return "Emergency vehicle priority", decision.reason
        label = e.label or e.vehicle_key
        return "Emergency vehicle priority", (
            f"{e.vehicle_type} {label} approaching on {e.approach_name or 'an approach'}, {e.distance_m:.0f} m away, "
            f"ETA {e.eta_s:.0f} s; green held for {decision.priority_phase}.")

    # -- the state machine --------------------------------------------------------------
    def step(
        self,
        policy: ControlPolicy,
        state: IntersectionState,
        plan: SignalPlan,
        network: NetworkState,
        node: IntersectionGeometry,
        now: datetime,
    ) -> tuple[SignalDecision | None, ControlStatus, ModeChange | None]:
        th = self.thresholds
        code = state.code
        track = self._tracks.get(code)
        first = track is None
        if track is None:
            track = _Track(ControlMode.FIXED_TIME, now, ControlMode.FIXED_TIME, now, policy)
            self._tracks[code] = track
        if track.policy != policy:
            track.policy, track.candidate_since = policy, None
        averaged = self._sample(track, state, now)
        snapshot = self._snapshot(track, state, averaged)
        level = level_for_rank(averaged) if averaged is not None else None
        pending: PendingSwitch | None = None

        if policy == ControlPolicy.FIXED:
            decision = None  # the actuator runs its local fixed plan
            self._set_base(track, ControlMode.FIXED_TIME, now)
            reason = ModeReason.MANUAL_FIXED
        elif policy == ControlPolicy.ADAPTIVE:
            decision = self.adaptive.decide(state, plan, network, node, now)
            if decision.algorithm == Algorithm.FIXED_TIME:
                self._set_base(track, ControlMode.FIXED_TIME, now)
                reason = ModeReason.INSUFFICIENT_DATA
            else:
                self._set_base(track, ControlMode.ADAPTIVE, now)
                reason = ModeReason.MANUAL_ADAPTIVE
        else:
            congested = (
                level is not None and level.rank >= th.enter_level.rank
                and (snapshot.window_estimated_vehicles or 0.0) >= th.min_vehicles
            )
            if track.base_mode == ControlMode.FIXED_TIME:
                if congested:
                    track.candidate_since = track.candidate_since or now
                    held = (now - track.candidate_since).total_seconds()
                    if held >= th.enter_hold_s:
                        self._set_base(track, ControlMode.ADAPTIVE, now)
                        reason = self._congested_reason(level)
                    else:
                        reason = ModeReason.CONGESTION_DETECTED
                        pending = PendingSwitch(ControlMode.ADAPTIVE, th.enter_hold_s - held, "if congestion persists")
                else:
                    track.candidate_since = None
                    reason = ModeReason.INSUFFICIENT_DATA if level is None else ModeReason.NORMAL_TRAFFIC
            else:
                if level is None:
                    self._set_base(track, ControlMode.FIXED_TIME, now)
                    reason = ModeReason.INSUFFICIENT_DATA
                elif level.rank <= th.exit_level.rank or (snapshot.window_estimated_vehicles or 0.0) < th.min_vehicles:
                    track.candidate_since = track.candidate_since or now
                    held = (now - track.candidate_since).total_seconds()
                    dwell = (now - track.base_since).total_seconds()
                    wait = max(th.exit_hold_s - held, th.min_adaptive_s - dwell)
                    if wait <= 0:
                        self._set_base(track, ControlMode.FIXED_TIME, now)
                        reason = ModeReason.CONGESTION_CLEARED
                    else:
                        reason = ModeReason.CONGESTION_EASING
                        pending = PendingSwitch(ControlMode.FIXED_TIME, wait, "if traffic stays normal")
                elif congested:
                    track.candidate_since = None
                    reason = self._congested_reason(level)
                else:
                    # Between the exit and enter levels: keep adaptive timing (hysteresis).
                    track.candidate_since = None
                    reason = ModeReason.CONGESTION_EASING
            controller = self.adaptive if track.base_mode == ControlMode.ADAPTIVE else self.fixed
            decision = controller.decide(state, plan, network, node, now)
            if track.base_mode == ControlMode.ADAPTIVE and decision.algorithm == Algorithm.FIXED_TIME:
                # The adaptive controller fell back to the fixed plan (no demand data at all).
                self._set_base(track, ControlMode.FIXED_TIME, now)
                reason = ModeReason.INSUFFICIENT_DATA

        headline, detail = self._explain(reason, snapshot, pending)
        effective = track.base_mode
        if decision is not None and decision.algorithm == Algorithm.EMERGENCY_PRIORITY:
            effective = ControlMode.EMERGENCY_PRIORITY
            reason = ModeReason.EMERGENCY_VEHICLE
            headline, detail = self._emergency_text(state, decision)
            pending = None

        change = None
        if effective != track.effective:
            if not first:
                change = ModeChange(code, now, track.effective, effective, reason, headline, detail, snapshot)
            track.effective, track.effective_since = effective, now

        fixed_timing, fixed_cycle = phase_timings(plan, {p.name: p.fixed_green_s for p in plan.phases})
        if decision is not None:
            active_timing, active_cycle = phase_timings(plan, {g.phase: g.green_s for g in decision.phase_greens})
        else:
            active_timing, active_cycle = fixed_timing, fixed_cycle
        status = ControlStatus(
            code=code, policy=policy, mode=effective, base_mode=track.base_mode, reason=reason,
            headline=headline, detail=detail, since=track.effective_since, pending=pending, traffic=snapshot,
            fixed_timing=fixed_timing, fixed_cycle_s=fixed_cycle, active_timing=active_timing,
            active_cycle_s=active_cycle, algorithm=decision.algorithm if decision else None,
            priority_phase=decision.priority_phase if decision else None,
        )
        return decision, status, change

    @staticmethod
    def _congested_reason(level: CongestionLevel) -> ModeReason:
        return ModeReason.SEVERE_CONGESTION if level == CongestionLevel.SEVERE else ModeReason.HIGH_CONGESTION

    @staticmethod
    def _set_base(track: _Track, mode: ControlMode, now: datetime) -> bool:
        if track.base_mode == mode:
            return False
        track.base_mode, track.base_since, track.candidate_since = mode, now, None
        return True
