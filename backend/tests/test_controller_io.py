from app.core.time import utcnow
from app.models.enums import UserRole
from app.services.runner import runner
from tests.conftest import API
from tests.helpers import LAT, LON0, seed_corridor


async def _key(client, as_role, ids, codes, kind="SUMO_BRIDGE", name="sumo"):
    admin = await as_role(UserRole.ADMIN, f"admin-{name}@example.com")
    r = await client.post(f"{API}/admin/controller-clients", headers=admin, json={
        "name": name, "kind": kind, "intersectionIds": [ids[c] for c in codes]})
    assert r.status_code == 201, r.text
    return {"X-Controller-Key": r.json()["apiKey"]}


async def test_sumo_observations_feed_the_engine(client, as_role, session_factory):
    ids = await seed_corridor(session_factory, adaptive=True)
    key = await _key(client, as_role, ids, ["I1", "I2", "I3", "I4"])
    vehicles = [
        {"externalId": f"flow.{i}", "lat": LAT, "lon": LON0 + 0.0065 - 0.0006 - i * 0.00007,
         "speedMps": 0.0, "headingDeg": 90.0}
        for i in range(8)
    ]
    r = await client.post(f"{API}/controller/observations", headers=key, json={"vehicles": vehicles})
    assert r.status_code == 200 and r.json() == {"acceptedVehicles": 8, "acceptedCounts": 0,
                                                  "ignoredCounts": 0, "source": "SUMO"}
    snapshot = await runner.run_cycle(session_factory)
    i2 = snapshot.state.intersections["I2"].metrics
    assert i2.observed.vehicle_count == 8 and i2.fully_observed and i2.sources == ["SUMO"]
    assert i2.estimated_vehicle_count == 8  # simulators are not scaled by penetration
    assert snapshot.state.intersections["I4"].metrics.congestion_level.value == "LOW"  # observed empty

    r = await client.get(f"{API}/controller/decisions", headers=key)
    decisions = {d["intersectionCode"]: d for d in r.json()["decisions"]}
    assert decisions["I2"]["algorithm"] == "DEMAND_PROPORTIONAL" and len(r.json()["plans"]) == 4

    state = (await client.get(f"{API}/controller/traffic-state", headers=key)).json()
    assert {s["code"] for s in state} == {"I1", "I2", "I3", "I4"}


async def test_camera_counts_are_scoped(client, as_role, session_factory):
    ids = await seed_corridor(session_factory)
    key = await _key(client, as_role, ids, ["I3"], kind="CAMERA", name="cam-i3")
    r = await client.post(f"{API}/controller/observations", headers=key, json={"counts": [
        {"intersectionCode": "I3", "approachName": "Northbound", "vehicleCount": 14},
        {"intersectionCode": "I1", "approachName": "Northbound", "vehicleCount": 99},
    ]})
    assert r.json()["acceptedCounts"] == 1 and r.json()["ignoredCounts"] == 1
    snapshot = await runner.run_cycle(session_factory)
    north = next(a for a in snapshot.state.intersections["I3"].metrics.approaches if a.approach_name == "Northbound")
    assert north.detector_count == 14


async def test_signal_state_reports_are_scoped(client, as_role, session_factory):
    ids = await seed_corridor(session_factory)
    key = await _key(client, as_role, ids, ["I1"], kind="RASPBERRY_PI", name="pi-i1")
    report = {"intersectionCode": "I1", "phaseName": "Eastbound+Westbound", "state": "GREEN",
              "mode": "FIXED_LOCAL", "remainingS": 12, "reportedAt": utcnow().isoformat()}
    r = await client.post(f"{API}/controller/signal-states", headers=key, json={"states": [report]})
    assert r.status_code == 204
    r = await client.post(f"{API}/controller/signal-states", headers=key,
                          json={"states": [report | {"intersectionCode": "I2"}]})
    assert r.status_code == 403 and r.json()["error"]["code"] == "OUT_OF_SCOPE"

    manager = await as_role(UserRole.MANAGER)
    items = (await client.get(f"{API}/signals/overview", headers=manager)).json()
    i1 = next(i for i in items if i["code"] == "I1")
    assert i1["connected"] is True and i1["state"]["state"] == "GREEN" and i1["state"]["source"] == "RASPBERRY_PI"
    overview = (await client.get(f"{API}/traffic/overview", headers=manager)).json()
    assert overview["connectedIntersections"] == 1


async def test_non_sumo_clients_cannot_flag_emergencies(client, as_role, session_factory):
    ids = await seed_corridor(session_factory)
    key = await _key(client, as_role, ids, ["I1"], kind="OTHER", name="other")
    await client.post(f"{API}/controller/observations", headers=key, json={"vehicles": [
        {"externalId": "x", "lat": LAT, "lon": LON0 - 0.001, "speedMps": 10, "headingDeg": 90, "emergency": True}]})
    snapshot = await runner.run_cycle(session_factory)
    assert snapshot.state.intersections["I1"].emergencies == []


async def test_invalid_key_rejected(client):
    r = await client.get(f"{API}/controller/decisions", headers={"X-Controller-Key": "stc_nope"})
    assert r.status_code == 401
