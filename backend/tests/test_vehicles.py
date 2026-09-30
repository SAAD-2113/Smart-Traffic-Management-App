from app.models.enums import UserRole
from tests.conftest import API


async def _driver(as_role, email="driver@example.com"):
    return await as_role(UserRole.END_USER, email)


async def _register(client, headers, **overrides):
    payload = {"vehicleType": "NORMAL", "displayName": "My car"} | overrides
    return await client.post(f"{API}/vehicles", headers=headers, json=payload)


async def test_normal_vehicles_get_sequential_codes(client, as_role):
    headers = await _driver(as_role)
    first = await _register(client, headers)
    second = await _register(client, headers, displayName="Second car")
    assert first.status_code == 201, first.text
    assert first.json()["code"] == "VH-0001"
    assert second.json()["code"] == "VH-0002"
    assert first.json()["emergencyAuthorized"] is False
    assert first.json()["emergencyAuthorization"] is None


async def test_emergency_type_requires_registration_number(client, as_role):
    headers = await _driver(as_role)
    r = await _register(client, headers, vehicleType="AMBULANCE")
    assert r.status_code == 422


async def test_emergency_vehicle_starts_pending_and_unauthorized(client, as_role):
    headers = await _driver(as_role)
    r = await _register(client, headers, vehicleType="AMBULANCE", registrationNumber="lea 1234")
    assert r.status_code == 201
    body = r.json()
    assert body["code"] == "EV-0001"
    assert body["registrationNumber"] == "LEA1234"
    assert body["emergencyAuthorization"]["status"] == "PENDING"
    assert body["emergencyAuthorized"] is False


async def test_vehicle_limit(client, as_role):
    headers = await _driver(as_role)
    for _ in range(3):
        assert (await _register(client, headers)).status_code == 201
    r = await _register(client, headers)
    assert r.status_code == 409 and r.json()["error"]["code"] == "VEHICLE_LIMIT_REACHED"


async def test_owner_sees_own_vehicles_only(client, as_role):
    alice = await _driver(as_role, "alice@example.com")
    bob = await _driver(as_role, "bob@example.com")
    vehicle_id = (await _register(client, alice)).json()["id"]

    assert (await client.get(f"{API}/vehicles/{vehicle_id}", headers=alice)).status_code == 200
    r = await client.get(f"{API}/vehicles/{vehicle_id}", headers=bob)
    assert r.status_code == 404  # 404, not 403: other people's ids are not confirmed to exist

    mine = await client.get(f"{API}/me/vehicles", headers=bob)
    assert mine.status_code == 200 and mine.json() == []


async def test_manager_view_hides_personal_fields(client, as_role):
    driver = await _driver(as_role)
    manager = await as_role(UserRole.MANAGER)
    vehicle_id = (await _register(client, driver, vehicleType="POLICE", registrationNumber="PK-99")).json()["id"]

    r = await client.get(f"{API}/manager/vehicles/{vehicle_id}", headers=manager)
    assert r.status_code == 200
    body = r.json()
    assert body["code"] == "EV-0001"
    for hidden in ("registrationNumber", "displayName", "ownerUserId"):
        assert hidden not in body


async def test_admin_view_includes_owner(client, as_role):
    driver = await _driver(as_role)
    admin = await as_role(UserRole.ADMIN)
    vehicle_id = (await _register(client, driver)).json()["id"]
    r = await client.get(f"{API}/admin/vehicles/{vehicle_id}", headers=admin)
    assert r.status_code == 200 and "ownerUserId" in r.json()


async def test_non_end_users_cannot_register_vehicles(client, as_role):
    manager = await as_role(UserRole.MANAGER)
    r = await _register(client, manager)
    assert r.status_code == 403


async def test_single_active_device_per_vehicle(client, as_role):
    headers = await _driver(as_role)
    vehicle_id = (await _register(client, headers)).json()["id"]
    url = f"{API}/vehicles/{vehicle_id}/devices"

    a = await client.post(url, headers=headers, json={"installationId": "install-aaaa-1111", "platform": "ANDROID"})
    b = await client.post(url, headers=headers, json={"installationId": "install-bbbb-2222", "platform": "ANDROID"})
    assert a.status_code == b.status_code == 200
    assert b.json()["status"] == "ACTIVE"

    devices = {d["installationId"]: d["status"] for d in (await client.get(url, headers=headers)).json()}
    assert devices == {"install-aaaa-1111": "INACTIVE", "install-bbbb-2222": "ACTIVE"}


async def test_rebinding_same_installation_is_idempotent(client, as_role):
    headers = await _driver(as_role)
    vehicle_id = (await _register(client, headers)).json()["id"]
    url = f"{API}/vehicles/{vehicle_id}/devices"
    body = {"installationId": "install-same-0001", "platform": "ANDROID", "appVersion": "0.1.0"}
    first = await client.post(url, headers=headers, json=body)
    second = await client.post(url, headers=headers, json=body | {"appVersion": "0.1.1"})
    assert first.json()["id"] == second.json()["id"]
    assert second.json()["appVersion"] == "0.1.1"


async def test_installation_moves_between_vehicles(client, as_role):
    headers = await _driver(as_role)
    v1 = (await _register(client, headers)).json()["id"]
    v2 = (await _register(client, headers, displayName="Second")).json()["id"]
    body = {"installationId": "install-phone-0001", "platform": "ANDROID"}
    await client.post(f"{API}/vehicles/{v1}/devices", headers=headers, json=body)
    await client.post(f"{API}/vehicles/{v2}/devices", headers=headers, json=body)

    v1_devices = (await client.get(f"{API}/vehicles/{v1}/devices", headers=headers)).json()
    v2_devices = (await client.get(f"{API}/vehicles/{v2}/devices", headers=headers)).json()
    assert v1_devices[0]["status"] == "INACTIVE"
    assert v2_devices[0]["status"] == "ACTIVE"


async def test_unbind_device(client, as_role):
    headers = await _driver(as_role)
    vehicle_id = (await _register(client, headers)).json()["id"]
    url = f"{API}/vehicles/{vehicle_id}/devices"
    device = (await client.post(url, headers=headers, json={"installationId": "install-unbd-0001", "platform": "ANDROID"})).json()
    assert (await client.delete(f"{url}/{device['id']}", headers=headers)).status_code == 204
    assert (await client.get(url, headers=headers)).json()[0]["status"] == "INACTIVE"


async def test_suspended_vehicle_cannot_bind_device(client, as_role):
    driver = await _driver(as_role)
    manager = await as_role(UserRole.MANAGER)
    vehicle_id = (await _register(client, driver)).json()["id"]

    r = await client.patch(f"{API}/manager/vehicles/{vehicle_id}/status", headers=manager,
                           json={"status": "SUSPENDED", "reason": "Implausible GPS data"})
    assert r.status_code == 200 and r.json()["status"] == "SUSPENDED"

    r = await client.post(f"{API}/vehicles/{vehicle_id}/devices", headers=driver,
                          json={"installationId": "install-susp-0001", "platform": "ANDROID"})
    assert r.status_code == 409 and r.json()["error"]["code"] == "VEHICLE_NOT_ACTIVE"
