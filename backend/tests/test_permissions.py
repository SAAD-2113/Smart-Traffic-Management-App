from app.models.enums import UserRole
from tests.conftest import API, PASSWORD


async def test_unauthenticated_requests_rejected(client):
    for path in ("/me", "/manager/vehicles", "/intersections", "/admin/controller-clients"):
        r = await client.get(f"{API}{path}")
        assert r.status_code == 401, path


async def test_end_user_cannot_use_manager_or_admin_routes(client, as_role):
    driver = await as_role(UserRole.END_USER)
    assert (await client.get(f"{API}/manager/vehicles", headers=driver)).status_code == 403
    assert (await client.get(f"{API}/intersections", headers=driver)).status_code == 403
    r = await client.post(f"{API}/admin/managers", headers=driver,
                          json={"email": "m@example.com", "password": PASSWORD, "fullName": "M"})
    assert r.status_code == 403


async def test_manager_cannot_use_admin_routes(client, as_role):
    manager = await as_role(UserRole.MANAGER)
    r = await client.post(f"{API}/admin/managers", headers=manager,
                          json={"email": "m2@example.com", "password": PASSWORD, "fullName": "M Two"})
    assert r.status_code == 403 and r.json()["error"]["code"] == "FORBIDDEN"


async def test_admin_creates_manager_who_can_log_in(client, as_role, login):
    admin = await as_role(UserRole.ADMIN)
    r = await client.post(f"{API}/admin/managers", headers=admin,
                          json={"email": "ops@example.com", "password": PASSWORD, "fullName": "Ops Manager"})
    assert r.status_code == 201 and r.json()["role"] == "MANAGER"
    _, body = await login("ops@example.com")
    assert body["user"]["role"] == "MANAGER"


async def test_admin_cannot_disable_self(client, as_role, login):
    admin = await as_role(UserRole.ADMIN)
    me = (await client.get(f"{API}/me", headers=admin)).json()
    r = await client.patch(f"{API}/admin/users/{me['id']}/status", headers=admin, json={"isActive": False})
    assert r.status_code == 409


async def test_manager_vehicle_list_and_filters(client, as_role):
    driver = await as_role(UserRole.END_USER)
    manager = await as_role(UserRole.MANAGER)
    await client.post(f"{API}/vehicles", headers=driver, json={"displayName": "Car"})
    await client.post(f"{API}/vehicles", headers=driver,
                      json={"vehicleType": "AMBULANCE", "displayName": "Amb", "registrationNumber": "AMB-1"})

    everything = (await client.get(f"{API}/manager/vehicles", headers=manager)).json()
    assert everything["total"] == 2
    ambulances = (await client.get(f"{API}/manager/vehicles?vehicleType=AMBULANCE", headers=manager)).json()
    assert ambulances["total"] == 1 and ambulances["items"][0]["code"] == "EV-0001"


async def test_end_user_cannot_suspend_vehicles(client, as_role):
    driver = await as_role(UserRole.END_USER)
    vehicle_id = (await client.post(f"{API}/vehicles", headers=driver, json={"displayName": "Car"})).json()["id"]
    r = await client.patch(f"{API}/manager/vehicles/{vehicle_id}/status", headers=driver,
                           json={"status": "SUSPENDED", "reason": "trying"})
    assert r.status_code == 403


async def test_manager_cannot_retire_vehicles(client, as_role):
    driver = await as_role(UserRole.END_USER)
    manager = await as_role(UserRole.MANAGER)
    vehicle_id = (await client.post(f"{API}/vehicles", headers=driver, json={"displayName": "Car"})).json()["id"]
    r = await client.patch(f"{API}/manager/vehicles/{vehicle_id}/status", headers=manager,
                           json={"status": "RETIRED", "reason": "not allowed"})
    assert r.status_code == 422
