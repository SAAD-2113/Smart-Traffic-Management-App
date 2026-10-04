"""One engine cycle: filter → map → aggregate → network state → decisions."""
from collections.abc import Iterable, Mapping
from dataclasses import dataclass, field
from datetime import datetime

from traffic_engine.aggregation import StopTracker, aggregate
from traffic_engine.control import SignalController, SignalDecision, SignalPlan, adaptive_controller, default_plan
from traffic_engine.control.modes import ControlPolicy, ControlStatus, ModeChange, ModeController, ModeThresholds
from traffic_engine.mapping import MappedObservation, map_observation
from traffic_engine.model import DetectorCount, Network, Observation
from traffic_engine.network import NetworkState, build_network_state

LIVE_WINDOW_S = 15.0              # observations older than this do not describe current traffic
MAX_ACCURACY_FOR_METRICS_M = 50.0  # worse fixes cannot be placed on an approach reliably
FUTURE_TOLERANCE_S = 5.0


@dataclass
class CycleResult:
    state: NetworkState
    decisions: dict[str, SignalDecision]
    mapped: list[MappedObservation]
    ignored_observations: int
    control: dict[str, ControlStatus] = field(default_factory=dict)
    mode_changes: list[ModeChange] = field(default_factory=list)


def is_usable(obs: Observation, now: datetime) -> bool:
    age = (now - obs.recorded_at).total_seconds()
    return -FUTURE_TOLERANCE_S <= age <= LIVE_WINDOW_S and obs.accuracy_m <= MAX_ACCURACY_FOR_METRICS_M


class TrafficEngine:
    """Stateful for stop tracking and control modes (both span cycles). Create one per process."""

    def __init__(self, adaptive: SignalController | None = None, thresholds: ModeThresholds | None = None) -> None:
        self.stop_tracker = StopTracker()
        self.adaptive = adaptive or adaptive_controller()
        self.modes = ModeController(thresholds, adaptive=self.adaptive)

    def run_cycle(
        self,
        network: Network,
        observations: Iterable[Observation],
        now: datetime,
        *,
        plans: dict[str, SignalPlan] | None = None,
        adaptive_codes: Iterable[str] = (),
        policies: Mapping[str, ControlPolicy] | None = None,
        detector_counts: Iterable[DetectorCount] = (),
        fully_observed_codes: Iterable[str] = (),
    ) -> CycleResult:
        latest: dict[str, Observation] = {}
        ignored = 0
        for obs in observations:
            if not is_usable(obs, now):
                ignored += 1
                continue
            current = latest.get(obs.key)
            if current is None or obs.recorded_at > current.recorded_at:
                latest[obs.key] = obs

        mapped = [map_observation(obs, network) for obs in latest.values()]
        metrics = aggregate(
            mapped, network, now, self.stop_tracker, detector_counts, frozenset(fully_observed_codes)
        )
        state = build_network_state(network, metrics, mapped, now)

        # Every active intersection gets a control status; FIXED ones get no decision (the
        # actuator runs its local fixed plan). Unlisted intersections are treated as FIXED.
        all_policies = dict(policies or {})
        for code in adaptive_codes:
            all_policies.setdefault(code, ControlPolicy.ADAPTIVE)
        decisions: dict[str, SignalDecision] = {}
        control: dict[str, ControlStatus] = {}
        changes: list[ModeChange] = []
        plans = plans or {}
        for code, node_state in state.intersections.items():
            node = network.intersections.get(code)
            if node is None:
                continue
            plan = plans.get(code) or default_plan(node)
            policy = all_policies.get(code, ControlPolicy.FIXED)
            decision, status, change = self.modes.step(policy, node_state, plan, state, node, now)
            if decision is not None:
                decisions[code] = decision
            control[code] = status
            if change is not None:
                changes.append(change)
        self.modes.prune(set(control))
        return CycleResult(state=state, decisions=decisions, mapped=mapped, ignored_observations=ignored,
                           control=control, mode_changes=changes)
