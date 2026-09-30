from datetime import timedelta

from sqlalchemy import func, select

from app.core.config import get_settings
from app.core.time import utcnow
from app.models.enums import TelemetrySource, UserRole
from app.models.telemetry import VehicleTelemetry
from app.models.user import User
from app.services.demo_service import demo
from app.services.runner import runner
from tests.conftest import API
from tests.helpers import seed_corridor


async def test_demo_refused_when_disabled(client, as_role):
    manager = await as_role(UserRole.MANAGER)
    r = await client.post(f"{API}/demo/start", headers=manager, json={"vehicles": 5})
    assert r.status_code == 403 and r.json()["error"]["code"] == "DEMO_DISABLED"
    assert (await client.get(f"{API}/demo/status", headers=manager)).json()["enabled"] is False


async def test_demo_fleet_runs_through_the_real_pipeline(client, as_role, session_factory, monkeypatch):
    monkeypatch.setattr(get_settings(), "demo_mode", True)
    await seed_corridor(session_factory, adaptive=True)
    manager = await as_role(UserRole.MANAGER)
    async with session_factory() as db:
        actor = await db.scalar(select(User).where(User.role == UserRole.MANAGER))
    status = await demo.start(session_factory, actor, 12, True, 5, run_loop=False)
    assert status.running and status.vehicles == 13

    now = utcnow()
    for i in range(90):  # 90 simulated seconds
        await demo.tick(session_factory, now + timedelta(seconds=i))
        if i % 2 == 0:
            await runner.run_cycle(session_factory, now=now + timedelta(seconds=i))

    async with session_factory() as db:
        rows = await db.scalar(select(func.count()).select_from(VehicleTelemetry)
                               .where(VehicleTelemetry.source == TelemetrySource.SIMULATOR))
    assert rows > 100

    live = (await client.get(f"{API}/manager/live/vehicles", headers=manager)).json()
    assert live and all(v["isSimulated"] and v["code"].startswith("SIM-") for v in live)
    assert (await client.get(f"{API}/manager/live/vehicles?includeSimulated=false", headers=manager)).json() == []
    snapshot = runner.latest
    assert all(s.metrics.fully_observed for s in snapshot.state.intersections.values())
    assert snapshot.decisions  # adaptive intersections get decisions from simulated traffic
    signals = (await client.get(f"{API}/signals/overview", headers=manager)).json()
    assert all(s["connected"] and s["state"]["source"] == "SIMULATOR" for s in signals)
    overview = (await client.get(f"{API}/traffic/overview", headers=manager)).json()
    assert overview["simulatedVehicles"] == 13 and overview["totalRegisteredVehicles"] == 0

    events = (await client.get(f"{API}/manager/emergency/events", headers=manager)).json()
    assert any(e["vehicleType"] == "AMBULANCE" and e["isSimulated"] for e in events)
    pending = (await client.get(f"{API}/manager/emergency/authorizations", headers=manager)).json()
    assert pending == []  # simulated authorisations stay out of the real review queue

    await demo.stop(session_factory, actor)
    assert (await client.get(f"{API}/emergency/active", headers=manager)).json() == []
    assert not demo.running


async def test_demo_start_stop_api(client, as_role, session_factory, monkeypatch):
    monkeypatch.setattr(get_settings(), "demo_mode", True)
    await seed_corridor(session_factory)
    manager = await as_role(UserRole.MANAGER)
    r = await client.post(f"{API}/demo/start", headers=manager, json={"vehicles": 3, "seed": 1})
    assert r.status_code == 200 and r.json()["running"] is True
    assert (await client.post(f"{API}/demo/start", headers=manager, json={"vehicles": 3})).status_code == 409
    r = await client.post(f"{API}/demo/stop", headers=manager)
    assert r.status_code == 200 and r.json()["running"] is False


async def test_demo_needs_intersections(client, as_role, monkeypatch):
    monkeypatch.setattr(get_settings(), "demo_mode", True)
    manager = await as_role(UserRole.MANAGER)
    r = await client.post(f"{API}/demo/start", headers=manager, json={"vehicles": 3})
    assert r.status_code == 409 and r.json()["error"]["code"] == "NO_INTERSECTIONS"
