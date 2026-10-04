"""Fixed-time / adaptive control modes through the backend: API, mode log, live events, lights."""
from datetime import timedelta

from sqlalchemy import select
from traffic_engine import TrafficEngine
from traffic_engine.control import ModeThresholds

from app.core.config import get_settings
from app.core.time import utcnow
from app.models.enums import UserRole
from app.models.user import User
from app.api.v1 import controller as controller_api
from app.services import runner as runner_module
from app.services.demo_service import demo
from app.services.runner import runner
from tests.conftest import API
from tests.helpers import LAT, LON0, SPACING, seed_corridor
from tests.test_controller_io import _key

FAST = ModeThresholds(window_s=6, enter_hold_s=4, exit_hold_s=4, min_adaptive_s=6, min_vehicles=4)
PLAN_30_3 = {"phases": [
    {"name": "North/South", "approaches": ["Northbound", "Southbound"], "minGreenS": 10, "maxGreenS": 60,
     "fixedGreenS": 30, "yellowS": 3, "allRedS": 1},
    {"name": "East/West", "approaches": ["Eastbound", "Westbound"], "minGreenS": 10, "maxGreenS": 60,
     "fixedGreenS": 30, "yellowS": 3, "allRedS": 1},
]}


def queue_at_i2(n: int) -> list[dict]:
    """n stopped vehicles queued on I2's westbound... eastbound approach (west of the junction)."""
    return [{"externalId": f"q{i}", "lat": LAT, "lon": LON0 + SPACING - 0.0006 - i * 0.00007,
             "speedMps": 0.0, "headingDeg": 90.0} for i in range(n)]


async def _cycle(client, session_factory, key, vehicles, at, monkeypatch):
    monkeypatch.setattr(controller_api, "utcnow", lambda: at)  # the feed arrives at simulated time `at`
    r = await client.post(f"{API}/controller/observations", headers=key,
                          json={"observedAt": at.isoformat(), "vehicles": vehicles})
    assert r.status_code == 200, r.text
    return await runner.run_cycle(session_factory, now=at)


async def _traffic(client, headers, code):
    items = (await client.get(f"{API}/traffic/intersections", headers=headers)).json()
    return next(i for i in items if i["code"] == code)


async def test_auto_intersection_runs_the_configured_fixed_plan_with_virtual_lights(client, as_role, session_factory):
    ids = await seed_corridor(session_factory, policy="AUTO")
    manager = await as_role(UserRole.MANAGER)
    r = await client.put(f"{API}/intersections/{ids['I1']}/signal-plan", headers=manager, json=PLAN_30_3)
    assert r.status_code == 200
    await runner.run_cycle(session_factory)

    i1 = await _traffic(client, manager, "I1")
    control = i1["control"]
    assert control["policy"] == "AUTO" and control["mode"] == "FIXED_TIME"
    assert control["reason"] == "INSUFFICIENT_DATA" and control["headline"] == "Not enough traffic data"
    ns = control["fixedTiming"][0]
    assert (ns["phase"], ns["greenS"], ns["yellowS"], ns["allRedS"]) == ("North/South", 30, 3, 1)
    assert control["fixedCycleS"] == 68 and ns["redS"] == 68 - 30 - 3
    assert control["activeTiming"] == control["fixedTiming"]
    assert i1["decision"]["algorithm"] == "FIXED_TIME"  # AUTO publishes the fixed plan as its decision

    lights = i1["displaySignal"]
    assert lights["virtual"] is True and lights["source"] == "VIRTUAL"
    heads = {h["approach"]: h["light"] for h in lights["heads"]}
    assert set(heads) == {"Northbound", "Southbound", "Eastbound", "Westbound"}
    assert heads["Northbound"] == heads["Southbound"] == "GREEN" and lights["phaseName"] == "North/South"
    assert heads["Eastbound"] == heads["Westbound"] == "RED"
    assert {h["approach"]: h["bearingDeg"] for h in lights["heads"]}["Eastbound"] == 90.0

    overview = (await client.get(f"{API}/traffic/overview", headers=manager)).json()
    assert overview["fixedTimeIntersections"] == 4 and overview["adaptiveIntersections"] == 0


async def test_congestion_switches_to_adaptive_and_back_with_reasons(client, as_role, session_factory, monkeypatch):
    runner.engine = TrafficEngine(thresholds=FAST)
    events = []
    real_queue = runner_module.queue_event
    monkeypatch.setattr(runner_module, "queue_event",
                        lambda db, kind, **data: (events.append((kind, data)), real_queue(db, kind, **data)))
    ids = await seed_corridor(session_factory, policy="AUTO")
    key = await _key(client, as_role, ids, ["I1", "I2", "I3", "I4"])
    manager = await as_role(UserRole.MANAGER)

    base = utcnow()
    t = 0
    snapshot = None
    while t <= 10:
        snapshot = await _cycle(client, session_factory, key, queue_at_i2(12), base + timedelta(seconds=t), monkeypatch)
        t += 2
    assert snapshot.control["I2"].mode.value == "ADAPTIVE"
    i2 = await _traffic(client, manager, "I2")
    control = i2["control"]
    assert control["mode"] == "ADAPTIVE" and control["reason"] in ("HIGH_CONGESTION", "SEVERE_CONGESTION")
    assert control["headline"].endswith("congestion detected")
    assert control["traffic"]["vehicleCount"] == 12 and control["traffic"]["averagedLevel"] == "SEVERE"
    assert "km/h" in control["detail"]
    assert i2["decision"]["algorithm"] == "DEMAND_PROPORTIONAL"
    assert control["activeTiming"] != control["fixedTiming"]
    overview = (await client.get(f"{API}/traffic/overview", headers=manager)).json()
    assert overview["adaptiveIntersections"] == 1

    while t <= 30:
        snapshot = await _cycle(client, session_factory, key, [], base + timedelta(seconds=t), monkeypatch)
        t += 2
    assert snapshot.control["I2"].mode.value == "FIXED_TIME"

    log = (await client.get(f"{API}/signals/mode-events", headers=manager)).json()
    assert [(e["intersectionCode"], e["fromMode"], e["toMode"]) for e in log] == [
        ("I2", "ADAPTIVE", "FIXED_TIME"), ("I2", "FIXED_TIME", "ADAPTIVE")]
    assert log[1]["reason"] in ("HIGH_CONGESTION", "SEVERE_CONGESTION") and log[1]["traffic"]["vehicleCount"] == 12
    assert log[0]["reason"] == "CONGESTION_CLEARED" and log[0]["headline"] == "Congestion cleared"
    only_i1 = await client.get(f"{API}/signals/mode-events", headers=manager, params={"intersectionId": ids["I1"]})
    assert only_i1.json() == []
    assert [e[1]["toMode"] for e in events if e[0] == "MODE_CHANGED"] == ["ADAPTIVE", "FIXED_TIME"]


async def test_fixed_policy_reports_manual_fixed_without_a_decision(client, as_role, session_factory):
    await seed_corridor(session_factory, policy="FIXED")
    manager = await as_role(UserRole.MANAGER)
    await runner.run_cycle(session_factory)
    i3 = await _traffic(client, manager, "I3")
    assert i3["control"]["mode"] == "FIXED_TIME" and i3["control"]["reason"] == "MANUAL_FIXED"
    assert i3["decision"] is None and i3["control"]["algorithm"] is None


async def test_a_connected_signal_controller_replaces_the_virtual_lights(client, as_role, session_factory):
    ids = await seed_corridor(session_factory, policy="AUTO")
    key = await _key(client, as_role, ids, ["I1"], kind="RASPBERRY_PI", name="pi-i1")
    report = {"intersectionCode": "I1", "phaseName": "Eastbound+Westbound", "state": "YELLOW",
              "mode": "FIXED_LOCAL", "remainingS": 2, "reportedAt": utcnow().isoformat()}
    assert (await client.post(f"{API}/controller/signal-states", headers=key, json={"states": [report]})).status_code == 204
    manager = await as_role(UserRole.MANAGER)
    items = (await client.get(f"{API}/signals/overview", headers=manager)).json()
    i1 = next(i for i in items if i["code"] == "I1")
    lights = i1["displaySignal"]
    assert lights["virtual"] is False and lights["source"] == "RASPBERRY_PI" and lights["state"] == "YELLOW"
    heads = {h["approach"]: h["light"] for h in lights["heads"]}
    assert heads == {"Northbound": "RED", "Eastbound": "YELLOW", "Southbound": "RED", "Westbound": "YELLOW"}
    assert i1["control"]["policy"] == "AUTO"
    i2 = next(i for i in items if i["code"] == "I2")
    assert i2["displaySignal"]["virtual"] is True


async def test_control_config_and_mode_log_are_manager_only(client, as_role):
    driver = await as_role(UserRole.END_USER)
    for path in ("/signals/control-config", "/signals/mode-events"):
        assert (await client.get(f"{API}{path}", headers=driver)).status_code == 403
    manager = await as_role(UserRole.MANAGER, "m2@example.com")
    config = (await client.get(f"{API}/signals/control-config", headers=manager)).json()
    settings = get_settings()
    assert config["enterLevel"] == settings.control_enter_level and config["exitLevel"] == settings.control_exit_level
    assert config["windowS"] == settings.control_window_s and config["minVehicles"] == settings.control_min_vehicles
    assert any("emergency" in rule for rule in config["rules"])


async def test_new_intersections_default_to_auto(client, as_role):
    manager = await as_role(UserRole.MANAGER)
    r = await client.post(f"{API}/intersections", headers=manager, json={
        "code": "J9", "name": "New junction", "latitude": 31.52, "longitude": 74.40, "radiusM": 40,
        "approachRadiusM": 250})
    assert r.status_code == 201, r.text
    assert r.json()["controllerType"] == "AUTO"


async def test_demo_rush_hour_surge(client, as_role, session_factory, monkeypatch):
    manager = await as_role(UserRole.MANAGER)
    r = await client.post(f"{API}/demo/surge", headers=manager, json={"intersectionCode": "I2"})
    assert r.status_code == 409 and r.json()["error"]["code"] == "DEMO_NOT_RUNNING"

    monkeypatch.setattr(get_settings(), "demo_mode", True)
    await seed_corridor(session_factory, policy="AUTO")
    async with session_factory() as db:
        actor = await db.scalar(select(User).where(User.role == UserRole.MANAGER))
    await demo.start(session_factory, actor, 10, False, 3, run_loop=False)
    try:
        r = await client.post(f"{API}/demo/surge", headers=manager, json={"intersectionCode": "i2", "durationS": 300})
        assert r.status_code == 200, r.text
        assert r.json()["surgeIntersectionCode"] == "I2" and r.json()["surgeRemainingS"] == 300
        r = await client.post(f"{API}/demo/surge", headers=manager, json={"intersectionCode": "I9"})
        assert r.status_code == 404
        r = await client.post(f"{API}/demo/surge/stop", headers=manager)
        assert r.json()["surgeIntersectionCode"] is None
    finally:
        await demo.stop(session_factory, None)
