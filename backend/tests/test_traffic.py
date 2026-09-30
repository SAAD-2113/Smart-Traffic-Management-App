from datetime import timedelta

from app.core.time import utcnow
from app.models.enums import UserRole
from app.services.runner import runner
from tests.conftest import API
from tests.helpers import LAT, LON0, ago, driver_with_vehicle, packet, seed_corridor, send, start_tracking


async def _probe_near_i1(client, as_role, email="driver@example.com", install="test-install-0001", speed=0.0):
    headers, vehicle_id = await driver_with_vehicle(client, as_role, email=email, install=install)
    session_id = await start_tracking(client, headers, vehicle_id)
    r = await send(client, headers, vehicle_id, session_id,
                   packet(1, at=ago(1), lat=LAT, lon=LON0 - 0.0006, speed=speed, heading=None))
    assert r.json()["accepted"] == 1
    return headers, vehicle_id


async def test_single_probe_metrics_are_labelled(client, as_role, session_factory):
    await seed_corridor(session_factory)
    await _probe_near_i1(client, as_role)
    manager = await as_role(UserRole.MANAGER)
    items = (await client.get(f"{API}/traffic/intersections", headers=manager)).json()
    i1 = next(i for i in items if i["code"] == "I1")
    assert i1["observed"]["vehicleCount"] == 1 and i1["observed"]["stoppedCount"] == 1
    assert i1["dataQuality"] == "LOW"
    assert i1["estimated"]["vehicleCount"] == 20.0 and i1["estimated"]["penetrationRate"] == 0.05
    assert i1["congestionLevel"] == "SEVERE"  # a stopped probe: speed ratio 0
    east = next(a for a in i1["approaches"] if a["name"] == "Eastbound")
    assert east["observed"]["vehicleCount"] == 1
    i3 = next(i for i in items if i["code"] == "I3")
    assert i3["congestionLevel"] == "UNKNOWN" and i3["dataQuality"] == "NONE"
    assert {d["toCode"] for d in next(i for i in items if i["code"] == "I2")["downstream"]} == {"I1", "I3"}


async def test_overview_counts(client, as_role, session_factory):
    await seed_corridor(session_factory)
    await _probe_near_i1(client, as_role, speed=8.0)
    manager = await as_role(UserRole.MANAGER)
    o = (await client.get(f"{API}/traffic/overview", headers=manager)).json()
    assert o["totalRegisteredVehicles"] == 1 and o["activeVehicles"] == 1 and o["transmittingVehicles"] == 1
    assert o["averageSpeedMps"] == 8.0 and o["activeIntersections"] == 4 and o["totalIntersections"] == 4
    assert o["emergencyVehicles"] == 0 and o["system"]["database"] == "ok"


async def test_adaptive_decisions_are_stored_and_served(client, as_role, session_factory):
    ids = await seed_corridor(session_factory, adaptive=True)
    await _probe_near_i1(client, as_role)
    await runner.run_cycle(session_factory)
    manager = await as_role(UserRole.MANAGER)
    overview = (await client.get(f"{API}/signals/overview", headers=manager)).json()
    i1 = next(i for i in overview if i["code"] == "I1")
    assert i1["decision"]["algorithm"] == "DEMAND_PROPORTIONAL" and i1["decision"]["advisory"] is True
    assert i1["plan"]["isDefault"] is True and len(i1["plan"]["phases"]) == 2
    i3 = next(i for i in overview if i["code"] == "I3")
    assert i3["decision"]["algorithm"] == "FIXED_TIME"  # no data → fixed fallback, and says so
    assert "No vehicle observations" in i3["decision"]["reason"]

    await runner.run_cycle(session_factory, now=utcnow() + timedelta(seconds=2))
    history = (await client.get(f"{API}/intersections/{ids['I1']}/signal-decisions", headers=manager)).json()
    assert len(history) == 1  # unchanged decision extends validity instead of adding rows


async def test_fixed_intersections_get_no_decisions(client, as_role, session_factory):
    await seed_corridor(session_factory, adaptive=False)
    await _probe_near_i1(client, as_role)
    snapshot = await runner.run_cycle(session_factory)
    assert snapshot.decisions == {}


async def test_signal_plan_validation(client, as_role, session_factory):
    ids = await seed_corridor(session_factory)
    manager = await as_role(UserRole.MANAGER)
    url = f"{API}/intersections/{ids['I2']}/signal-plan"
    plan = (await client.get(url, headers=manager)).json()
    assert plan["isDefault"] is True and plan["fixedCycleS"] == 60

    good = {"phases": [
        {"name": "EW", "approaches": ["Eastbound", "Westbound"], "minGreenS": 12, "maxGreenS": 70,
         "fixedGreenS": 35, "yellowS": 4, "allRedS": 2},
        {"name": "NS", "approaches": ["Northbound", "Southbound"], "minGreenS": 8, "maxGreenS": 40,
         "fixedGreenS": 20, "yellowS": 3, "allRedS": 2},
    ], "minCycleS": 45, "maxCycleS": 130}
    r = await client.put(url, headers=manager, json=good)
    assert r.status_code == 200 and r.json()["isDefault"] is False and r.json()["fixedCycleS"] == 66

    bad = {"phases": [
        {"name": "EW", "approaches": ["Eastbound", "Diagonal"], "minGreenS": 3, "maxGreenS": 70,
         "fixedGreenS": 35, "yellowS": 1, "allRedS": 2},
        {"name": "NS", "approaches": ["Eastbound"], "minGreenS": 8, "maxGreenS": 40,
         "fixedGreenS": 20, "yellowS": 3, "allRedS": 2},
    ]}
    r = await client.put(url, headers=manager, json=bad)
    assert r.status_code == 422 and r.json()["error"]["code"] == "INVALID_SIGNAL_PLAN"
    messages = " ".join(d["message"] for d in r.json()["error"]["details"])
    assert "minimum green" in messages and "yellow" in messages and "Diagonal" in messages
    assert "more than one phase" in messages


async def test_metric_history(client, as_role, session_factory):
    ids = await seed_corridor(session_factory)
    await _probe_near_i1(client, as_role)
    await runner.run_cycle(session_factory)
    await runner.run_cycle(session_factory, now=utcnow() + timedelta(seconds=31))
    manager = await as_role(UserRole.MANAGER)
    h = (await client.get(f"{API}/traffic/intersections/{ids['I1']}/history?hours=1&bucketS=30",
                          headers=manager)).json()
    assert h["code"] == "I1" and len(h["points"]) >= 1
    assert h["points"][0]["observedVehicles"] >= 1
    network = (await client.get(f"{API}/traffic/history", headers=manager)).json()
    assert {s["code"] for s in network["series"]} == {"I1", "I2", "I3", "I4"}


async def test_traffic_endpoints_are_manager_only(client, as_role):
    driver = await as_role(UserRole.END_USER)
    for path in ("/traffic/overview", "/traffic/intersections", "/signals/overview", "/manager/live/vehicles",
                 "/traffic/history", "/demo/status"):
        assert (await client.get(f"{API}{path}", headers=driver)).status_code == 403, path


async def test_live_vehicles_hide_personal_data_and_filter_simulated(client, as_role, session_factory):
    await seed_corridor(session_factory)
    _, vehicle_id = await _probe_near_i1(client, as_role)
    manager = await as_role(UserRole.MANAGER)
    items = (await client.get(f"{API}/manager/live/vehicles", headers=manager)).json()
    assert len(items) == 1
    for hidden in ("displayName", "registrationNumber", "ownerUserId"):
        assert hidden not in items[0]
    track = (await client.get(f"{API}/manager/vehicles/{vehicle_id}/telemetry?minutes=5", headers=manager)).json()
    assert len(track) == 1 and track[0]["isLive"] is True
    assert (await client.get(f"{API}/manager/live/vehicles?includeSimulated=false", headers=manager)).json()
