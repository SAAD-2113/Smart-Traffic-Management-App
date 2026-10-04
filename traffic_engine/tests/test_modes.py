"""Fixed-time / adaptive mode switching (control/modes.py)."""
from datetime import timedelta

import pytest
from traffic_engine.aggregation import ApproachMetrics, IntersectionMetrics, ObservedStats
from traffic_engine.control import (
    Algorithm,
    ControlMode,
    ControlPolicy,
    ModeController,
    ModeReason,
    ModeThresholds,
    Phase,
    SignalPlan,
)
from traffic_engine.model import CongestionLevel, DataQuality, Zone
from traffic_engine.network import EmergencyApproach, IntersectionState, NetworkState

from tests.conftest import NOW

PLAN = SignalPlan(phases=(
    Phase("North/South", ("Northbound", "Southbound"), min_green_s=10, max_green_s=60, fixed_green_s=30,
          yellow_s=3, all_red_s=1),
    Phase("East/West", ("Eastbound", "Westbound"), min_green_s=10, max_green_s=60, fixed_green_s=30,
          yellow_s=3, all_red_s=1),
))
FAST = ModeThresholds(window_s=10, enter_hold_s=6, exit_hold_s=8, min_adaptive_s=12, min_vehicles=8)


def state(level: CongestionLevel, vehicles: int = 20, quality: DataQuality = DataQuality.HIGH,
          speed: float | None = 3.0, emergencies=None) -> IntersectionState:
    approach = ApproachMetrics(
        approach_name="Eastbound", observed=ObservedStats(vehicle_count=vehicles, avg_speed_mps=speed),
        speed_ratio=None, avg_waiting_time_s=None, max_waiting_time_s=None,
        estimated_vehicle_count=float(vehicles), density_veh_per_km_lane=None,
        congestion_level=level, data_quality=quality,
    )
    metrics = IntersectionMetrics(
        code="I2", observed=ObservedStats(vehicle_count=vehicles, avg_speed_mps=speed, speed_sample_count=vehicles),
        core_count=0, departure_count=0, speed_ratio=None, avg_waiting_time_s=25.0,
        estimated_vehicle_count=float(vehicles), density_veh_per_km_lane=None,
        congestion_level=level, data_quality=quality, approaches=[approach],
    )
    return IntersectionState(code="I2", name="I2", metrics=metrics, emergencies=emergencies or [])


class Clock:
    """Feeds the controller one state every 2 s, like the engine cycle."""

    def __init__(self, corridor, thresholds=FAST):
        self.node = corridor.intersections["I2"]
        self.modes = ModeController(thresholds)
        self.now = NOW
        self.changes = []

    def run(self, seconds: float, st: IntersectionState, policy=ControlPolicy.AUTO):
        result = None
        for _ in range(int(seconds // 2) or 1):
            network = NetworkState(self.now, {"I2": st})
            decision, status, change = self.modes.step(policy, st, PLAN, network, self.node, self.now)
            if change:
                self.changes.append(change)
            result = (decision, status)
            self.now += timedelta(seconds=2)
        return result


def test_normal_traffic_runs_the_configured_fixed_plan(corridor):
    clock = Clock(corridor)
    decision, status = clock.run(20, state(CongestionLevel.MODERATE, speed=9.0))
    assert status.mode == ControlMode.FIXED_TIME and status.reason == ModeReason.NORMAL_TRAFFIC
    assert decision.algorithm == Algorithm.FIXED_TIME
    assert [t.green_s for t in status.active_timing] == [30, 30]
    ns = status.fixed_timing[0]
    assert (ns.green_s, ns.yellow_s, ns.all_red_s) == (30, 3, 1)
    assert status.fixed_cycle_s == 68 and ns.red_s == 68 - 30 - 3
    assert "fixed-time plan is running" in status.detail
    assert clock.changes == []


def test_sustained_congestion_switches_to_adaptive_with_reason(corridor):
    clock = Clock(corridor)
    clock.run(10, state(CongestionLevel.LOW, speed=10.0))
    _, status = clock.run(4, state(CongestionLevel.SEVERE, vehicles=42, speed=3.3))
    # The average needs to reach HIGH first, then the hold timer runs.
    _, status = clock.run(4, state(CongestionLevel.SEVERE, vehicles=42, speed=3.3))
    assert status.mode == ControlMode.FIXED_TIME
    assert status.reason == ModeReason.CONGESTION_DETECTED and status.pending is not None
    assert status.pending.to_mode == ControlMode.ADAPTIVE and status.pending.in_s > 0
    decision, status = clock.run(10, state(CongestionLevel.SEVERE, vehicles=42, speed=3.3))
    assert status.mode == ControlMode.ADAPTIVE
    assert status.reason in (ModeReason.HIGH_CONGESTION, ModeReason.SEVERE_CONGESTION)
    assert status.headline.endswith("congestion detected")
    assert "km/h" in status.detail and "vehicles" in status.detail
    assert decision.algorithm == Algorithm.DEMAND_PROPORTIONAL
    assert status.traffic.vehicle_count == 42
    change = clock.changes[-1]
    assert (change.from_mode, change.to_mode) == (ControlMode.FIXED_TIME, ControlMode.ADAPTIVE)


def test_a_short_spike_does_not_switch(corridor):
    clock = Clock(corridor, ModeThresholds(window_s=10, enter_hold_s=30, min_vehicles=8))
    clock.run(10, state(CongestionLevel.LOW, speed=10.0))
    clock.run(12, state(CongestionLevel.SEVERE, vehicles=30))
    _, status = clock.run(16, state(CongestionLevel.LOW, speed=10.0))
    assert status.mode == ControlMode.FIXED_TIME and clock.changes == []


def test_a_few_queued_vehicles_are_not_congestion(corridor):
    clock = Clock(corridor)
    _, status = clock.run(40, state(CongestionLevel.SEVERE, vehicles=3, speed=0.5))
    assert status.mode == ControlMode.FIXED_TIME and status.reason == ModeReason.NORMAL_TRAFFIC
    assert status.headline == "Light traffic" and "fewer than the 8 needed" in status.detail


def test_returns_to_fixed_only_after_traffic_stays_normal(corridor):
    clock = Clock(corridor)
    clock.run(30, state(CongestionLevel.SEVERE, vehicles=40))
    assert clock.changes[-1].to_mode == ControlMode.ADAPTIVE
    _, status = clock.run(14, state(CongestionLevel.LOW, vehicles=2, speed=11.0))
    assert status.mode == ControlMode.ADAPTIVE and status.reason == ModeReason.CONGESTION_EASING
    assert status.pending.to_mode == ControlMode.FIXED_TIME
    decision, status = clock.run(16, state(CongestionLevel.LOW, vehicles=2, speed=11.0))
    assert status.mode == ControlMode.FIXED_TIME
    assert clock.changes[-1].reason == ModeReason.CONGESTION_CLEARED
    assert decision.algorithm == Algorithm.FIXED_TIME


def test_moderate_traffic_keeps_adaptive_timing(corridor):
    clock = Clock(corridor)
    clock.run(30, state(CongestionLevel.SEVERE, vehicles=40))
    _, status = clock.run(30, state(CongestionLevel.MODERATE, vehicles=20, speed=7.0))
    assert status.mode == ControlMode.ADAPTIVE and status.reason == ModeReason.CONGESTION_EASING
    assert status.pending is None and "until traffic has been LOW" in status.detail


def test_too_little_data_keeps_fixed_and_leaves_adaptive(corridor):
    clock = Clock(corridor)
    _, status = clock.run(20, state(CongestionLevel.SEVERE, vehicles=2, quality=DataQuality.LOW))
    assert status.mode == ControlMode.FIXED_TIME and status.reason == ModeReason.INSUFFICIENT_DATA
    assert "not enough to judge congestion" in status.detail

    clock = Clock(corridor)
    clock.run(30, state(CongestionLevel.SEVERE, vehicles=40))
    _, status = clock.run(12, state(CongestionLevel.UNKNOWN, vehicles=0, quality=DataQuality.NONE, speed=None))
    assert status.mode == ControlMode.FIXED_TIME and status.reason == ModeReason.INSUFFICIENT_DATA


def test_manual_policies_skip_the_rules(corridor):
    clock = Clock(corridor)
    decision, status = clock.run(20, state(CongestionLevel.SEVERE, vehicles=40), ControlPolicy.FIXED)
    assert decision is None and status.mode == ControlMode.FIXED_TIME
    assert status.reason == ModeReason.MANUAL_FIXED and status.algorithm is None
    decision, status = clock.run(2, state(CongestionLevel.LOW, vehicles=10), ControlPolicy.ADAPTIVE)
    assert status.mode == ControlMode.ADAPTIVE and status.reason == ModeReason.MANUAL_ADAPTIVE
    assert decision.algorithm == Algorithm.DEMAND_PROPORTIONAL


def test_emergency_vehicle_overrides_either_mode(corridor):
    clock = Clock(corridor)
    clock.run(10, state(CongestionLevel.LOW, speed=10.0))
    ambulance = EmergencyApproach("ev", "EV-0001", "AMBULANCE", "Eastbound", Zone.APPROACH, 120.0, 9.0, "MOBILE")
    decision, status = clock.run(2, state(CongestionLevel.LOW, speed=10.0, emergencies=[ambulance]))
    assert status.mode == ControlMode.EMERGENCY_PRIORITY and status.base_mode == ControlMode.FIXED_TIME
    assert status.reason == ModeReason.EMERGENCY_VEHICLE and "EV-0001" in status.detail
    assert decision.priority_phase == "East/West"
    assert clock.changes[-1].to_mode == ControlMode.EMERGENCY_PRIORITY
    _, status = clock.run(2, state(CongestionLevel.LOW, speed=10.0))
    assert status.mode == ControlMode.FIXED_TIME
    assert clock.changes[-1].from_mode == ControlMode.EMERGENCY_PRIORITY


def test_adaptive_timing_differs_from_fixed_and_red_follows_the_cycle(corridor):
    clock = Clock(corridor)
    _, status = clock.run(30, state(CongestionLevel.SEVERE, vehicles=40))
    assert status.mode == ControlMode.ADAPTIVE
    for t in status.active_timing:
        assert t.red_s == pytest.approx(status.active_cycle_s - t.green_s - t.yellow_s, abs=0.11)
    assert status.active_cycle_s == pytest.approx(sum(t.green_s + t.yellow_s + t.all_red_s for t in status.active_timing))


def test_threshold_validation():
    assert ModeThresholds().validate() == []
    assert ModeThresholds(enter_level=CongestionLevel.LOW, exit_level=CongestionLevel.LOW).validate()
    assert ModeThresholds(min_data_quality=DataQuality.NONE).validate()
    with pytest.raises(ValueError):
        ModeController(ModeThresholds(window_s=0))
