from datetime import timedelta

from traffic_engine import TrafficEngine
from traffic_engine.control import (
    Algorithm,
    DemandProportionalController,
    EmergencyPriorityController,
    FixedTimeController,
    Phase,
    SignalPlan,
    default_plan,
)
from traffic_engine.model import Observation, Source

from tests.conftest import NOW, offset
from tests.test_aggregation import queue

PLAN = SignalPlan(phases=(
    Phase("EW", ("Eastbound", "Westbound"), min_green_s=10, max_green_s=60, fixed_green_s=25),
    Phase("NS", ("Northbound", "Southbound"), min_green_s=10, max_green_s=60, fixed_green_s=25),
))


def cycle(network, observations, adaptive=("I1", "I2", "I3", "I4"), engine=None, now=NOW):
    engine = engine or TrafficEngine()
    plans = {code: PLAN for code in network.intersections}
    return engine.run_cycle(network, observations, now, plans=plans, adaptive_codes=adaptive)


def test_default_plan_pairs_opposite_approaches(corridor):
    plan = default_plan(corridor.intersections["I1"])
    groups = sorted(sorted(p.approaches) for p in plan.phases)
    assert groups == [["Eastbound", "Westbound"], ["Northbound", "Southbound"]]
    assert plan.validate() == []


def test_plan_validation_catches_unsafe_values():
    bad = SignalPlan(phases=(
        Phase("A", ("Eastbound",), min_green_s=3, fixed_green_s=20, max_green_s=30, yellow_s=1),
        Phase("A", ("Eastbound",)),
    ))
    errors = " ".join(bad.validate())
    assert "unique" in errors and "minimum green" in errors and "yellow" in errors and "more than one phase" in errors


def test_fixed_controller_returns_plan(corridor):
    engine = TrafficEngine(adaptive=FixedTimeController())
    result = cycle(corridor, [], engine=engine)
    d = result.decisions["I1"]
    assert d.algorithm == Algorithm.FIXED_TIME
    assert [g.green_s for g in d.phase_greens] == [25, 25]
    assert d.cycle_s == 60
    assert d.valid_until - d.created_at == timedelta(seconds=15)


def test_no_data_falls_back_to_fixed_with_reason(corridor):
    result = cycle(corridor, [])
    d = result.decisions["I2"]
    assert d.algorithm == Algorithm.FIXED_TIME and "No vehicle observations" in d.reason


def test_heavier_phase_gets_more_green_within_limits(corridor):
    result = cycle(corridor, queue(corridor, "I1", 12))
    d = result.decisions["I1"]
    assert d.algorithm == Algorithm.DEMAND_PROPORTIONAL
    ew, ns = d.green_for("EW"), d.green_for("NS")
    assert ew > ns
    assert 10 <= ns <= 60 and 10 <= ew <= 60
    assert 40 <= d.cycle_s <= 120 + 1
    assert "Eastbound" in d.reason and d.inputs["flowRatios"]["EW"] > 0


def test_adaptive_cycle_never_shorter_than_fixed_plan(corridor):
    # A modest queue: plain Webster would pick a cycle shorter than the fixed 60 s plan,
    # which would give even the busy phase less green than fixed-time.
    observations = queue(corridor, "I1", 6)
    webster = cycle(corridor, observations, engine=TrafficEngine(
        adaptive=DemandProportionalController(fixed_cycle_floor=False))).decisions["I1"]
    assert webster.cycle_s < PLAN.fixed_cycle_s
    d = cycle(corridor, observations).decisions["I1"]
    assert d.algorithm == Algorithm.DEMAND_PROPORTIONAL
    assert d.cycle_s >= PLAN.fixed_cycle_s
    assert d.green_for("EW") > 25 > d.green_for("NS")  # green moved to the busy phase
    assert d.inputs["cycleFloorS"] == PLAN.fixed_cycle_s and "raised to the fixed plan" in d.reason


def test_upstream_arrivals_raise_demand_before_queue_forms(corridor):
    arriving = []
    for i in range(6):  # heading east on link I1 -> I2, ~300 m from I2 at 10 m/s → ETA 30 s
        lat, lon = offset("I1", corridor, 90.0, 290.0 + 5 * i)
        arriving.append(Observation(key=f"a{i}", source=Source.SIMULATOR, lat=lat, lon=lon, recorded_at=NOW,
                                    speed_mps=10.0, heading_deg=90.0))
    result = cycle(corridor, arriving)
    i2 = result.state.intersections["I2"]
    upstream = next(u for u in i2.upstream if u.from_code == "I1")
    assert upstream.expected_arrivals_60s == 6
    east = next(a for a in i2.metrics.approaches if a.approach_name == "Eastbound")
    assert east.expected_arrivals_60s == 6
    d = result.decisions["I2"]
    assert d.algorithm == Algorithm.DEMAND_PROPORTIONAL and d.green_for("EW") > d.green_for("NS")


def test_downstream_severe_congestion_gates_feeding_phase(corridor):
    feeding = queue(corridor, "I1", 10, prefix="a", speed=0.0)          # EW demand at I1
    jam = queue(corridor, "I2", 12, prefix="j", speed=0.0)              # I2 severe
    gated = cycle(corridor, feeding + jam).decisions["I1"]
    free = cycle(corridor, feeding).decisions["I1"]
    assert gated.green_for("EW") < free.green_for("EW")
    assert "Gated" in gated.reason


def test_emergency_vehicle_gets_priority_phase(corridor):
    lat, lon = offset("I3", corridor, 180.0, 150.0)  # south of I3, heading north
    ambulance = Observation(key="ev", source=Source.MOBILE, lat=lat, lon=lon, recorded_at=NOW, speed_mps=12.0,
                            heading_deg=0.0, emergency=True, vehicle_type="AMBULANCE", label="EV-0001")
    result = cycle(corridor, [ambulance])
    state = result.state.intersections["I3"]
    assert state.emergencies[0].approach_name == "Northbound"
    d = result.decisions["I3"]
    assert d.algorithm == Algorithm.EMERGENCY_PRIORITY and d.priority_phase == "NS"
    assert "EV-0001" in d.reason and "simulation" in d.reason
    assert d.green_for("NS") >= 10


def test_emergency_far_away_does_not_preempt(corridor):
    lat, lon = offset("I1", corridor, 90.0, 300.0)  # on link to I2, ETA ~ 25 s at 12 m/s... make it slow
    slow = Observation(key="ev", source=Source.MOBILE, lat=lat, lon=lon, recorded_at=NOW, speed_mps=3.0,
                       heading_deg=90.0, emergency=True, vehicle_type="AMBULANCE")
    d = cycle(corridor, [slow]).decisions["I2"]  # 300 m at 3 m/s = 100 s > 60 s
    assert d.priority_phase is None


def test_materially_differs(corridor):
    engine = TrafficEngine()
    a = cycle(corridor, queue(corridor, "I1", 12), engine=engine).decisions["I1"]
    b = cycle(corridor, queue(corridor, "I1", 12), engine=engine, now=NOW + timedelta(seconds=2)).decisions["I1"]
    assert not b.materially_differs(a)
    assert a.materially_differs(None)


def test_stale_and_inaccurate_observations_are_ignored(corridor):
    lat, lon = offset("I1", corridor, 270.0, 60.0)
    old = Observation(key="o", source=Source.MOBILE, lat=lat, lon=lon, recorded_at=NOW - timedelta(seconds=40))
    fuzzy = Observation(key="f", source=Source.MOBILE, lat=lat, lon=lon, recorded_at=NOW, accuracy_m=80)
    result = cycle(corridor, [old, fuzzy])
    assert result.ignored_observations == 2
    assert result.state.intersections["I1"].metrics.observed.vehicle_count == 0


def test_emergency_wrapper_is_transparent_without_emergencies(corridor):
    inner = DemandProportionalController()
    wrapped = EmergencyPriorityController(inner)
    engine = TrafficEngine(adaptive=wrapped)
    d = cycle(corridor, queue(corridor, "I1", 5), engine=engine).decisions["I1"]
    assert d.algorithm == Algorithm.DEMAND_PROPORTIONAL
