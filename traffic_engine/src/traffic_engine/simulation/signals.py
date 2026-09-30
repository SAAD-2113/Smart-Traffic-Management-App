"""Virtual signal controller used by the demo fleet (and as a reference for real actuators).

It runs the plan locally and applies an advisory decision only while it is valid, always
keeping minimum green, yellow and all-red times - the same rules ADR 0001 sets for the
Raspberry Pi controllers.
"""
from datetime import datetime
from enum import StrEnum

from traffic_engine.control.plan import Phase, SignalDecision, SignalPlan


class LightState(StrEnum):
    GREEN = "GREEN"
    YELLOW = "YELLOW"
    ALL_RED = "ALL_RED"


class SignalMode(StrEnum):
    FIXED_LOCAL = "FIXED_LOCAL"
    ADAPTIVE = "ADAPTIVE"
    EMERGENCY = "EMERGENCY"


class VirtualSignal:
    def __init__(self, code: str, plan: SignalPlan) -> None:
        self.code = code
        self.plan = plan
        self.phase_index = 0
        self.state = LightState.GREEN
        self.elapsed_s = 0.0
        self.decision: SignalDecision | None = None
        self.applied_decision_created_at: datetime | None = None

    # -- configuration -------------------------------------------------------------
    def set_plan(self, plan: SignalPlan) -> None:
        if [p.name for p in plan.phases] != [p.name for p in self.plan.phases]:
            self.phase_index, self.state, self.elapsed_s = 0, LightState.GREEN, 0.0
        self.plan = plan

    def apply(self, decision: SignalDecision | None) -> None:
        self.decision = decision

    # -- queries ---------------------------------------------------------------------
    @property
    def phase(self) -> Phase:
        return self.plan.phases[self.phase_index]

    def _valid_decision(self, now: datetime) -> SignalDecision | None:
        if self.decision is None or now >= self.decision.valid_until:
            return None
        return self.decision

    def mode(self, now: datetime) -> SignalMode:
        decision = self._valid_decision(now)
        if decision is None:
            return SignalMode.FIXED_LOCAL
        return SignalMode.EMERGENCY if decision.priority_phase else SignalMode.ADAPTIVE

    def green_target_s(self, now: datetime) -> float:
        phase = self.phase
        decision = self._valid_decision(now)
        target = phase.fixed_green_s
        if decision is not None:
            target = decision.green_for(phase.name) or phase.fixed_green_s
        return max(phase.min_green_s, min(phase.max_green_s, target))

    def remaining_s(self, now: datetime) -> float:
        if self.state == LightState.GREEN:
            return max(0.0, self.green_target_s(now) - self.elapsed_s)
        if self.state == LightState.YELLOW:
            return max(0.0, self.phase.yellow_s - self.elapsed_s)
        return max(0.0, self.phase.all_red_s - self.elapsed_s)

    def light_for(self, approach_name: str | None) -> LightState:
        """What a vehicle on this approach sees. Approaches in no phase are unsignalised."""
        phase = self.plan.phase_for_approach(approach_name)
        if phase is None:
            return LightState.GREEN
        if phase.name != self.phase.name:
            return LightState.ALL_RED
        return self.state

    # -- time ------------------------------------------------------------------------
    def step(self, dt: float, now: datetime) -> None:
        self.elapsed_s += dt
        decision = self._valid_decision(now)
        priority = decision.priority_phase if decision else None
        phase = self.phase

        if self.state == LightState.GREEN:
            preempt = priority is not None and priority != phase.name and self.elapsed_s >= phase.min_green_s
            if preempt or self.elapsed_s >= self.green_target_s(now):
                self.state, self.elapsed_s = LightState.YELLOW, 0.0
        elif self.state == LightState.YELLOW:
            if self.elapsed_s >= phase.yellow_s:
                self.state, self.elapsed_s = LightState.ALL_RED, 0.0
        elif self.elapsed_s >= phase.all_red_s:
            names = [p.name for p in self.plan.phases]
            if priority in names:
                self.phase_index = names.index(priority)
            else:
                self.phase_index = (self.phase_index + 1) % len(names)
            self.state, self.elapsed_s = LightState.GREEN, 0.0
            if decision is not None:
                self.applied_decision_created_at = decision.created_at
