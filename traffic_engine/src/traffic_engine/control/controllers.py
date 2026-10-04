"""Signal controllers. They all produce advisory decisions; none drives hardware directly.

Prototype status: these are transparent, explainable heuristics for demonstration and
comparison in simulation. They are not claimed to be optimal and are not certified for
controlling real traffic signals.
"""
from datetime import datetime, timedelta
from typing import Protocol

from traffic_engine.control.plan import (
    DECISION_VALIDITY_S,
    Algorithm,
    PhaseGreen,
    SignalDecision,
    SignalPlan,
)
from traffic_engine.geo import angle_diff_deg
from traffic_engine.model import CongestionLevel, DataQuality, IntersectionGeometry
from traffic_engine.network import IntersectionState, NetworkState

SATURATION_FLOW_VEH_PER_H_PER_LANE = 1800.0  # common planning default (assumption)
DEMAND_HORIZON_S = 60.0
MAX_FLOW_RATIO_SUM = 0.9
DOWNSTREAM_GATING_FACTOR = 0.6
EMERGENCY_PRIORITY_ETA_S = 60.0
EMERGENCY_CLEARANCE_MARGIN_S = 10.0


class SignalController(Protocol):
    name: str

    def decide(
        self,
        state: IntersectionState,
        plan: SignalPlan,
        network: NetworkState,
        node: IntersectionGeometry,
        now: datetime,
    ) -> SignalDecision: ...


def _decision(
    code: str, now: datetime, algorithm: Algorithm, plan: SignalPlan, greens: dict[str, float], reason: str,
    inputs: dict | None = None,
) -> SignalDecision:
    phase_greens = tuple(PhaseGreen(p.name, round(greens[p.name])) for p in plan.phases)
    cycle = sum(g.green_s for g in phase_greens) + plan.lost_time_s
    return SignalDecision(
        intersection_code=code,
        created_at=now,
        valid_until=now + timedelta(seconds=DECISION_VALIDITY_S),
        algorithm=algorithm,
        cycle_s=round(cycle, 1),
        phase_greens=phase_greens,
        reason=reason,
        inputs=inputs or {},
    )


class FixedTimeController:
    """The configured fixed plan. Baseline for comparisons and the fallback."""

    name = "fixed"

    def decide(self, state, plan, network, node, now) -> SignalDecision:
        greens = {p.name: p.fixed_green_s for p in plan.phases}
        return _decision(state.code, now, Algorithm.FIXED_TIME, plan, greens, "Fixed-time plan.")


class DemandProportionalController:
    """Webster-style cycle length and green split from observed and estimated demand.

    phase demand (veh)  = max over its approaches of (estimated queue + estimated arrivals in 60 s)
    flow ratio y        = demand / horizon / (saturation flow x lanes)
    cycle C             = (1.5 L + 5) / (1 - Y), clamped to the plan's cycle range
    green g_i           = (C - L) x y_i / Y, clamped to [min green, max green]
    Greens feeding a SEVERELY congested downstream intersection are reduced (gating).

    By default the cycle is never shorter than the fixed plan's cycle: adaptive timing moves
    green time to the busier phase and lengthens the cycle when demand is high, but does not
    cut the cycle below the configured plan (Webster's short cycles for light demand would
    otherwise give even the congested phase less green than the fixed plan).
    `fixed_cycle_floor=False` gives plain Webster within the plan's cycle range.
    """

    name = "demand_proportional"

    def __init__(self, fallback: FixedTimeController | None = None, fixed_cycle_floor: bool = True) -> None:
        self.fallback = fallback or FixedTimeController()
        self.fixed_cycle_floor = fixed_cycle_floor

    def decide(self, state, plan, network, node, now) -> SignalDecision:
        metrics = state.metrics
        approaches = {a.approach_name: a for a in metrics.approaches}
        has_arrivals = any(a.estimated_arrivals_60s > 0 for a in metrics.approaches)
        if metrics.data_quality == DataQuality.NONE and not has_arrivals:
            decision = self.fallback.decide(state, plan, network, node, now)
            return _decision(
                state.code, now, Algorithm.FIXED_TIME, plan, {g.phase: g.green_s for g in decision.phase_greens},
                "No vehicle observations near this intersection; using the fixed plan.",
                {"dataQuality": metrics.data_quality.value},
            )

        flow_ratios: dict[str, float] = {}
        demand_notes: list[str] = []
        for phase in plan.phases:
            best_ratio, best_note = 0.0, None
            for name in phase.approaches:
                a = approaches.get(name)
                geometry = node.approach(name)
                if a is None or geometry is None:
                    continue
                queue = a.estimated_vehicle_count or 0.0
                arrivals = a.estimated_arrivals_60s
                demand = queue + arrivals
                flow_per_h = demand / DEMAND_HORIZON_S * 3600.0
                ratio = flow_per_h / (SATURATION_FLOW_VEH_PER_H_PER_LANE * geometry.lanes)
                if ratio >= best_ratio:
                    best_ratio = ratio
                    best_note = f"{name} {demand:.0f} veh ({queue:.0f} queued + {arrivals:.0f} arriving)"
            flow_ratios[phase.name] = best_ratio
            if best_note:
                demand_notes.append(best_note)

        total = sum(flow_ratios.values())
        lost = plan.lost_time_s
        capped = min(total, MAX_FLOW_RATIO_SUM)
        webster = (1.5 * lost + 5.0) / (1.0 - capped)
        floor = max(plan.min_cycle_s, plan.fixed_cycle_s) if self.fixed_cycle_floor else plan.min_cycle_s
        cycle = min(plan.max_cycle_s, max(floor, webster))
        effective = cycle - lost

        greens: dict[str, float] = {}
        for phase in plan.phases:
            share = flow_ratios[phase.name] / total if total > 0 else 1.0 / len(plan.phases)
            greens[phase.name] = max(phase.min_green_s, min(phase.max_green_s, effective * share))

        gated: list[str] = []
        for phase in plan.phases:
            for name in phase.approaches:
                geometry = node.approach(name)
                if geometry is None:
                    continue
                for load in state.downstream:
                    if (
                        load.congestion_level == CongestionLevel.SEVERE
                        and angle_diff_deg(load.bearing_deg, geometry.travel_bearing_deg) <= 45.0
                    ):
                        reduced = max(phase.min_green_s, greens[phase.name] * DOWNSTREAM_GATING_FACTOR)
                        if reduced < greens[phase.name]:
                            greens[phase.name] = reduced
                            gated.append(f"{phase.name} (downstream {load.to_code} severe)")

        final_cycle = sum(round(g) for g in greens.values()) + lost
        reason = (
            f"Webster-style split, Y={total:.2f}, Webster cycle {webster:.0f} s, "
            + (f"raised to the fixed plan's {plan.fixed_cycle_s:.0f} s, " if webster < floor and floor > plan.min_cycle_s else "")
            + f"{final_cycle:.0f} s after green limits. " + "; ".join(demand_notes)
        )
        if gated:
            reason += ". Gated: " + ", ".join(sorted(set(gated)))
        inputs = {
            "flowRatios": {k: round(v, 3) for k, v in flow_ratios.items()},
            "flowRatioSum": round(total, 3),
            "lostTimeS": lost,
            "websterCycleS": round(webster, 1),
            "cycleFloorS": floor,
            "dataQuality": metrics.data_quality.value,
            "saturationFlowVehPerHPerLane": SATURATION_FLOW_VEH_PER_H_PER_LANE,
        }
        return _decision(state.code, now, Algorithm.DEMAND_PROPORTIONAL, plan, greens, reason, inputs)


class EmergencyPriorityController:
    """Wraps another controller and requests priority for an approaching emergency vehicle.

    SIMULATION / PROTOTYPE ONLY. The decision asks the actuator to serve the priority phase
    next and hold it long enough for the vehicle to pass, but the actuator must still honour
    minimum green and clearance intervals, and may refuse.
    """

    name = "emergency_priority"

    def __init__(self, inner: SignalController) -> None:
        self.inner = inner

    def decide(self, state, plan, network, node, now) -> SignalDecision:
        decision = self.inner.decide(state, plan, network, node, now)
        for emergency in state.emergencies:
            if emergency.eta_s is None or emergency.eta_s > EMERGENCY_PRIORITY_ETA_S:
                continue
            phase = plan.phase_for_approach(emergency.approach_name)
            if phase is None:
                continue
            green = max(decision.green_for(phase.name) or 0.0, phase.min_green_s)
            green = min(phase.max_green_s, max(green, emergency.eta_s + EMERGENCY_CLEARANCE_MARGIN_S))
            label = emergency.label or emergency.vehicle_key
            reason = (
                f"Emergency priority (simulation/advisory): {emergency.vehicle_type} {label} on "
                f"{emergency.approach_name}, {emergency.distance_m:.0f} m away, ETA {emergency.eta_s:.0f} s. "
                f"Base timing: {decision.reason}"
            )
            return decision.with_priority(
                phase.name, round(green), reason,
                {"emergencyVehicle": label, "emergencyEtaS": round(emergency.eta_s, 1)},
            )
        return decision


def adaptive_controller() -> SignalController:
    """The controller used for intersections in ADAPTIVE mode."""
    return EmergencyPriorityController(DemandProportionalController())
