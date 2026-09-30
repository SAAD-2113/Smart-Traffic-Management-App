import uuid

from app.models.enums import UserRole
from tests.conftest import API


async def _intersection(client, manager):
    r = await client.post(f"{API}/intersections", headers=manager, json={
        "code": "I1", "name": "Pi test", "latitude": 31.52, "longitude": 74.35,
        "radiusM": 40, "approachRadiusM": 250})
    return r.json()["id"]


async def test_pi_key_lifecycle(client, as_role):
    admin = await as_role(UserRole.ADMIN)
    iid = await _intersection(client, admin)

    r = await client.post(f"{API}/admin/controller-clients", headers=admin, json={
        "name": "pi-i1", "kind": "RASPBERRY_PI", "intersectionIds": [iid]})
    assert r.status_code == 201, r.text
    created = r.json()
    key = created["apiKey"]
    assert key.startswith("stc_") and created["keyPrefix"] == key[:12]

    ping = await client.get(f"{API}/controller/ping", headers={"X-Controller-Key": key})
    assert ping.status_code == 200 and ping.json()["intersectionCodes"] == ["I1"]

    listed = (await client.get(f"{API}/admin/controller-clients", headers=admin)).json()
    assert "apiKey" not in listed[0] and listed[0]["lastSeenAt"] is not None

    await client.post(f"{API}/admin/controller-clients/{created['id']}/revoke", headers=admin)
    r = await client.get(f"{API}/controller/ping", headers={"X-Controller-Key": key})
    assert r.status_code == 401 and r.json()["error"]["code"] == "INVALID_CONTROLLER_KEY"


async def test_ping_requires_valid_key(client):
    assert (await client.get(f"{API}/controller/ping")).status_code == 401
    r = await client.get(f"{API}/controller/ping", headers={"X-Controller-Key": "stc_fake"})
    assert r.status_code == 401


async def test_user_tokens_do_not_work_as_controller_keys(client, as_role):
    manager = await as_role(UserRole.MANAGER)
    assert (await client.get(f"{API}/controller/ping", headers=manager)).status_code == 401


async def test_only_admin_creates_controller_clients(client, as_role):
    manager = await as_role(UserRole.MANAGER)
    iid = await _intersection(client, manager)
    r = await client.post(f"{API}/admin/controller-clients", headers=manager, json={
        "name": "pi-x", "kind": "RASPBERRY_PI", "intersectionIds": [iid]})
    assert r.status_code == 403


async def test_unknown_intersection_in_scope(client, as_role):
    admin = await as_role(UserRole.ADMIN)
    r = await client.post(f"{API}/admin/controller-clients", headers=admin, json={
        "name": "pi-ghost", "kind": "RASPBERRY_PI", "intersectionIds": [str(uuid.uuid4())]})
    assert r.status_code == 404


async def test_health(client):
    r = await client.get(f"{API}/health")
    assert r.status_code == 200 and r.json()["database"] == "ok"
