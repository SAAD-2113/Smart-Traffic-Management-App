"""Signal plans (configuration) and decisions (controller output)."""
from dataclasses import dataclass, field, replace
from datetime import datetime
from enum import StrEnum
from typing import Any

from traffic_engine.geo import angle_diff_deg
from traffic_engine.model import IntersectionGeometry

# Safety bounds a plan must respect. Actuators must enforce their own limits as well.
MIN_GREEN_FLOOR_S = 5.0
YELLOW_RANGE_S = (3.0, 6.0)
ALL_RED_RANGE_S = (1.0, 5.0)
DECISION_VALIDITY_S = 15.0


class Algorithm(StrEnum):
    FIXED_TIME = "FIXED_TIME"
    DEMAND_PROPORTIONAL = "DEMAND_PROPORTIONAL"
    EMERGENCY_PRIORITY = "EMERGENCY_PRIORITY"


@dataclass(frozen=True)
class Phase:
    name: str
    approaches: tuple[str, ...]
    min_green_s: float = 10.0
    max_green_s: float = 60.0
    fixed_green_s: float = 25.0
    yellow_s: float = 3.0
    all_red_s: float = 2.0

    @property
    def clearance_s(self) -> float:
        return self.yellow_s + self.all_red_s


@dataclass(frozen=True)
class SignalPlan:
    phases: tuple[Phase, ...]
    min_cycle_s: float = 40.0
    max_cycle_s: float = 120.0

    @property
    def lost_time_s(self) -> float:
        return sum(p.clearance_s for p in self.phases)

    @property
    def fixed_cycle_s(self) -> float:
        return sum(p.fixed_green_s + p.clearance_s for p in self.phases)

    def phase_for_approach(self, approach_name: str | None) -> Phase | None:
        if approach_name is None:
            return None
        return next((p for p in self.phases if approach_name in p.approaches), None)

    def validate(self) -> list[str]:
        """Human-readable problems; an empty list means the plan is acceptable."""
        errors: list[str] = []
        if not 2 <= len(self.phases) <= 8:
            errors.append("A plan needs between 2 and 8 phases.")
        names = [p.name for p in self.phases]
        if len(set(names)) != len(names):
            errors.append("Phase names must be unique.")
        seen: set[str] = set()
        for p in self.phases:
            if not p.name.strip():
                errors.append("Phase names cannot be empty.")
            if p.min_green_s < MIN_GREEN_FLOOR_S:
                errors.append(f"{p.name}: minimum green must be at least {MIN_GREEN_FLOOR_S:.0f} s.")
            if not p.min_green_s <= p.fixed_green_s <= p.max_green_s:
                errors.append(f"{p.name}: need minimum green <= fixed green <= maximum green.")
            if not YELLOW_RANGE_S[0] <= p.yellow_s <= YELLOW_RANGE_S[1]:
                errors.append(f"{p.name}: yellow must be {YELLOW_RANGE_S[0]:.0f}-{YELLOW_RANGE_S[1]:.0f} s.")
            if not ALL_RED_RANGE_S[0] <= p.all_red_s <= ALL_RED_RANGE_S[1]:
                errors.append(f"{p.name}: all-red must be {ALL_RED_RANGE_S[0]:.0f}-{ALL_RED_RANGE_S[1]:.0f} s.")
            for a in p.approaches:
                if a in seen:
                    errors.append(f"Approach '{a}' is served by more than one phase.")
                seen.add(a)
        if self.min_cycle_s >= self.max_cycle_s:
            errors.append("Minimum cycle must be shorter than maximum cycle.")
        min_possible = sum(p.min_green_s + p.clearance_s for p in self.phases)
        if min_possible > self.max_cycle_s:
            errors.append("Minimum greens plus clearance times exceed the maximum cycle.")
        return errors


def default_plan(node: IntersectionGeometry) -> SignalPlan:
    """Two-or-more-phase plan pairing opposite approaches (e.g. Eastbound + Westbound)."""
    remaining = sorted(node.approaches, key=lambda a: a.travel_bearing_deg)
    groups: list[list[str]] = []
    while remaining:
        first = remaining.pop(0)
        partner = next(
            (a for a in remaining if angle_diff_deg(a.travel_bearing_deg, first.travel_bearing_deg + 180) <= 30),
            None,
        )
        if partner is not None:
            remaining.remove(partner)
            groups.append([first.name, partner.name])
        else:
            groups.append([first.name])
    while len(groups) < 2:
        groups.append([])
    phases = tuple(
        Phase(name="+".join(g) if g else f"Phase {chr(65 + i)}", approaches=tuple(g))
        for i, g in enumerate(groups)
    )
    return SignalPlan(phases=phases)


@dataclass(frozen=True)
class PhaseGreen:
    phase: str
    green_s: float


@dataclass(frozen=True)
class SignalDecision:
    """Advisory timing for one intersection. Actuators ignore it after `valid_until`."""

    intersection_code: str
    created_at: datetime
    valid_until: datetime
    algorithm: Algorithm
    cycle_s: float
    phase_greens: tuple[PhaseGreen, ...]
    reason: str
    priority_phase: str | None = None
    inputs: dict[str, Any] = field(default_factory=dict)

    def green_for(self, phase: str) -> float | None:
        return next((g.green_s for g in self.phase_greens if g.phase == phase), None)

    def with_priority(self, phase: str, green_s: float, reason: str, inputs: dict[str, Any]) -> "SignalDecision":
        greens = tuple(PhaseGreen(g.phase, green_s if g.phase == phase else g.green_s) for g in self.phase_greens)
        return replace(
            self,
            algorithm=Algorithm.EMERGENCY_PRIORITY,
            phase_greens=greens,
            priority_phase=phase,
            reason=reason,
            inputs={**self.inputs, **inputs},
        )

    def materially_differs(self, other: "SignalDecision | None", tolerance_s: float = 2.0) -> bool:
        if other is None:
            return True
        if (self.algorithm, self.priority_phase) != (other.algorithm, other.priority_phase):
            return True
        if abs(self.cycle_s - other.cycle_s) > tolerance_s:
            return True
        mine = {g.phase: g.green_s for g in self.phase_greens}
        theirs = {g.phase: g.green_s for g in other.phase_greens}
        if mine.keys() != theirs.keys():
            return True
        return any(abs(mine[k] - theirs[k]) > tolerance_s for k in mine)
