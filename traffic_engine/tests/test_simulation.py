from datetime import timedelta
import pytest

from traffic_engine import TrafficEngine
from traffic_engine.control import Algorithm, PhaseGreen, SignalDecision
from traffic_engine.geo import haversine_m
from traffic_engine.model import CongestionLevel, Source
from traffic_engine.simulation import DemoFleet, LightState, SignalMode, VehicleSpec, VirtualSignal

from tests.conftest import NOW
from tests.test_control import PLAN


def test_virtual_signal_runs_fixed_plan_in_order():
    signal = VirtualSignal("I1", PLAN)
    states = []
    now = NOW
    for _ in range(int((25 + 3 + 2) * 2)):  # one full phase at 0.5 s steps
        signal.step(0.5, now)
        now += timedelta(seconds=0.5)
        states.append((signal.phase.name, signal.state))
    assert ("EW", LightState.YELLOW) in states and ("EW", LightState.ALL_RED) in states
    assert states[-1] == ("NS", LightState.GREEN)
    assert signal.light_for("Northbound") == LightState.GREEN
    assert signal.light_for("Eastbound") == LightState.ALL_RED
    assert signal.light_for("Unknown") == LightState.GREEN
    assert signal.mode(now) == SignalMode.FIXED_LOCAL


def test_priority_preempts_only_after_min_green():
    signal = VirtualSignal("I1", PLAN)
    decision = SignalDecision("I1", NOW, NOW + timedelta(seconds=60), Algorithm.EMERGENCY_PRIORITY, 60,
                              (PhaseGreen("EW", 20), PhaseGreen("NS", 30)), "test", priority_phase="NS")
    signal.apply(decision)
    now = NOW
    for _ in range(18):  # 9 s < min green 10 s
        signal.step(0.5, now)
        now += timedelta(seconds=0.5)
    assert (signal.phase.name, signal.state) == ("EW", LightState.GREEN)
    for _ in range(2 + 6 + 4 + 1):  # reach min green, then yellow 3 s and all-red 2 s
        signal.step(0.5, now)
        now += timedelta(seconds=0.5)
    assert (signal.phase.name, signal.state) == ("NS", LightState.GREEN)
    assert signal.mode(now) == SignalMode.EMERGENCY


def test_expired_decision_is_ignored():
    signal = VirtualSignal("I1", PLAN)
    signal.apply(SignalDecision("I1", NOW, NOW + timedelta(seconds=1), Algorithm.DEMAND_PROPORTIONAL, 100,
                                (PhaseGreen("EW", 55), PhaseGreen("NS", 35)), "x"))
    assert signal.green_target_s(NOW) == 55
    assert signal.green_target_s(NOW + timedelta(seconds=5)) == 25


def _run(corridor, seconds, adaptive=True, n=20):
    specs = [VehicleSpec(f"sim{i}", f"SIM-{i:04d}") for i in range(n)]
    specs.append(VehicleSpec("amb", "SIM-AMB", "AMBULANCE"))
    fleet = DemoFleet(corridor, specs, seed=3)
    signals = {code: VirtualSignal(code, PLAN) for code in corridor.intersections}
    engine = TrafficEngine()
    now = NOW
    history = []
    events = []
    for tick in range(int(seconds * 2)):
        fleet.step(0.5, now, signals)
        for s in signals.values():
            s.step(0.5, now)
        now += timedelta(seconds=0.5)
        if tick % 4 == 0:
            obs = fleet.observations(now)
            result = engine.run_cycle(corridor, obs, now, plans={c: PLAN for c in signals},
                                      adaptive_codes=list(signals) if adaptive else [],
                                      fully_observed_codes=list(signals))
            for code, decision in result.decisions.items():
                signals[code].apply(decision)
            history.append((obs, result))
        events.extend(fleet.drain_events())
    return fleet, history, events


def test_fleet_produces_valid_simulator_observations(corridor):
    fleet, history, events = _run(corridor, 120)
    assert fleet.active_count > 5
    obs, _ = history[-1]
    assert all(o.source == Source.SIMULATOR and 0 <= o.speed_mps < 25 for o in obs)
    assert all(3 <= o.accuracy_m <= 8 for o in obs)
    labels = {o.label for o in obs}
    assert len(labels) == len(obs)  # one observation per vehicle


def test_vehicles_queue_at_red_and_never_overlap(corridor):
    fleet, history, _ = _run(corridor, 240)
    stopped_near_junction = 0
    for obs, result in history:
        for m in result.mapped:
            if m.zone is not None and m.zone.value == "APPROACH" and m.observation.speed_mps < 0.5:
                stopped_near_junction += 1
    assert stopped_near_junction > 0
    for vehicle in fleet.vehicles:
        assert vehicle.v >= 0
    # no two active vehicles occupy the same spot on the same segment
    for v in fleet.vehicles:
        for w in fleet.vehicles:
            if v is w or not (v.active and w.active):
                continue
            i, j = v.route.segment_at(v.s), w.route.segment_at(w.s)
            if v.route.seg_keys[i] == w.route.seg_keys[j]:
                a = v.s - v.route.cum[i]
                b = w.s - w.route.cum[j]
                assert abs(a - b) >= 4.0


def test_emergency_trip_generates_events_and_priority(corridor):
    fleet, history, events = _run(corridor, 150)
    kinds = [(e.kind, e.vehicle_key) for e in events]
    assert ("EMERGENCY_STARTED", "amb") in kinds
    priorities = [d for _, r in history for d in r.decisions.values() if d.priority_phase]
    assert priorities, "an approaching ambulance should trigger at least one priority decision"


def test_congestion_emerges_and_is_classified(corridor):
    _, history, _ = _run(corridor, 300, n=30)
    levels = {s.metrics.congestion_level for _, r in history for s in r.state.intersections.values()}
    assert CongestionLevel.LOW in levels
    assert levels & {CongestionLevel.MODERATE, CongestionLevel.HIGH, CongestionLevel.SEVERE}
    assert CongestionLevel.UNKNOWN not in levels  # simulator fully observes its world


def test_routes_start_outside_and_pass_through_junctions(corridor):
    fleet = DemoFleet(corridor, [VehicleSpec("x", "X")], seed=1)
    fleet.step(25.0, NOW, {})
    vehicle = fleet.vehicles[0]
    assert vehicle.active
    first_node = corridor.intersections[vehicle.route.stops[0].node_code]
    start = vehicle.route.points[0]
    assert haversine_m(start[0], start[1], first_node.lat, first_node.lon) > first_node.approach_radius_m


def _first_stops(corridor, surge: bool) -> list[str]:
    specs = [VehicleSpec(f"sim{i}", f"SIM-{i:04d}") for i in range(30)]
    fleet = DemoFleet(corridor, specs, seed=5)
    signals = {code: VirtualSignal(code, PLAN) for code in corridor.intersections}
    if surge:
        fleet.start_surge("I2", 600)
        assert fleet.surge_active and fleet.surge_remaining_s == 600
    now = NOW
    stops = []
    for _ in range(600):
        fleet.step(0.5, now, signals)
        now += timedelta(seconds=0.5)
        for event in fleet.drain_events():
            if event.kind == "TRIP_STARTED":
                vehicle = next(v for v in fleet.vehicles if v.spec.key == event.vehicle_key)
                stops.append(vehicle.route.stops[0].node_code)
    return stops


def test_surge_sends_more_new_trips_through_one_intersection(corridor):
    normal = _first_stops(corridor, surge=False)
    surge = _first_stops(corridor, surge=True)
    assert len(surge) > 20
    normal_share = normal.count("I2") / len(normal)
    surge_share = surge.count("I2") / len(surge)
    assert surge_share > 0.45 and surge_share > 2 * normal_share


def test_surge_can_be_stopped_and_needs_a_known_intersection(corridor):
    fleet = DemoFleet(corridor, [VehicleSpec("sim0", "SIM-0000")], seed=5)
    fleet.start_surge("I3", 60)
    fleet.stop_surge()
    assert not fleet.surge_active and fleet.surge_remaining_s == 0
    with pytest.raises(ValueError):
        fleet.start_surge("I9", 60)
