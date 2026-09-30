from datetime import timedelta

from app.core.time import utcnow
from app.models.enums import UserRole
from app.services import emergency_service
from tests.conftest import API
from tests.helpers import ago, driver_with_vehicle, packet, send, start_tracking


async def _ambulance(client, as_role, approve=True):
    headers, vehicle_id = await driver_with_vehicle(client, as_role, vehicle_type="AMBULANCE")
    manager = await as_role(UserRole.MANAGER)
    if approve:
        pending = (await client.get(f"{API}/manager/emergency/authorizations?status=PENDING", headers=manager)).json()
        assert pending[0]["registrationNumber"] == "EMG-101"  # visible to managers for verification
        r = await client.post(f"{API}/manager/emergency/authorizations/{pending[0]['id']}/approve",
                              headers=manager, json={"notes": "Verified with hospital fleet office"})
        assert r.status_code == 200 and r.json()["status"] == "APPROVED"
    return headers, vehicle_id, manager


async def _start(client, headers, vehicle_id, confirm=True):
    return await client.post(f"{API}/vehicles/{vehicle_id}/emergency/start", headers=headers, json={"confirm": confirm})


async def test_normal_vehicle_cannot_activate(client, as_role):
    headers, vehicle_id = await driver_with_vehicle(client, as_role)
    r = await _start(client, headers, vehicle_id)
    assert r.status_code == 403 and r.json()["error"]["code"] == "NOT_EMERGENCY_VEHICLE"


async def test_pending_authorization_cannot_activate(client, as_role):
    headers, vehicle_id, _ = await _ambulance(client, as_role, approve=False)
    status = (await client.get(f"{API}/vehicles/{vehicle_id}/emergency", headers=headers)).json()
    assert status["authorizationStatus"] == "PENDING" and status["authorized"] is False
    r = await _start(client, headers, vehicle_id)
    assert r.status_code == 403 and r.json()["error"]["code"] == "EMERGENCY_NOT_AUTHORIZED"


async def test_activation_preconditions(client, as_role):
    headers, vehicle_id, _ = await _ambulance(client, as_role)
    r = await _start(client, headers, vehicle_id, confirm=False)
    assert r.status_code == 422 and r.json()["error"]["code"] == "CONFIRMATION_REQUIRED"
    r = await _start(client, headers, vehicle_id)
    assert r.status_code == 409 and r.json()["error"]["code"] == "TRACKING_NOT_ACTIVE"
    await start_tracking(client, headers, vehicle_id)
    r = await _start(client, headers, vehicle_id)
    assert r.status_code == 409 and r.json()["error"]["code"] == "NO_RECENT_LOCATION"


async def test_full_emergency_flow(client, as_role):
    headers, vehicle_id, manager = await _ambulance(client, as_role)
    session_id = await start_tracking(client, headers, vehicle_id)
    await send(client, headers, vehicle_id, session_id, packet(1, at=ago(2)))

    r = await _start(client, headers, vehicle_id)
    assert r.status_code == 200 and r.json()["status"] == "ACTIVE" and r.json()["vehicleCode"] == "EV-0001"
    again = await _start(client, headers, vehicle_id)
    assert again.json()["id"] == r.json()["id"]  # idempotent

    r = await send(client, headers, vehicle_id, session_id, packet(2, at=ago(1), emergency=False))
    assert r.json()["emergencyActive"] is True  # the server decides, not the packet
    live = (await client.get(f"{API}/vehicles/{vehicle_id}/telemetry/latest", headers=headers)).json()["live"]
    assert live["emergency"] is True

    active = (await client.get(f"{API}/emergency/active", headers=manager)).json()
    assert len(active) == 1 and active[0]["vehicleCode"] == "EV-0001" and active[0]["lat"] is not None
    live_list = (await client.get(f"{API}/manager/live/vehicles", headers=manager)).json()
    assert live_list[0]["emergencyActive"] is True and live_list[0]["trackingStatus"] == "TRANSMITTING"

    r = await client.post(f"{API}/vehicles/{vehicle_id}/emergency/stop", headers=headers)
    assert r.json()["status"] == "ENDED" and r.json()["endReason"] == "DRIVER"
    assert (await client.get(f"{API}/emergency/active", headers=manager)).json() == []
    events = (await client.get(f"{API}/manager/emergency/events", headers=manager)).json()
    assert events[0]["endReason"] == "DRIVER"


async def test_revocation_ends_emergency(client, as_role):
    headers, vehicle_id, manager = await _ambulance(client, as_role)
    session_id = await start_tracking(client, headers, vehicle_id)
    await send(client, headers, vehicle_id, session_id, packet(1, at=ago(3)))
    await _start(client, headers, vehicle_id)
    r = await client.post(f"{API}/manager/vehicles/{vehicle_id}/emergency-authorization/revoke",
                          headers=manager, json={"notes": "Vehicle decommissioned"})
    assert r.status_code == 200 and r.json()["status"] == "REVOKED"
    r = await send(client, headers, vehicle_id, session_id, packet(2, at=ago(1)))
    assert r.json()["emergencyActive"] is False
    events = (await client.get(f"{API}/manager/emergency/events", headers=manager)).json()
    assert events[0]["endReason"] == "AUTH_REVOKED"
    assert (await _start(client, headers, vehicle_id)).status_code == 403


async def test_manager_force_end_and_stop_tracking(client, as_role):
    headers, vehicle_id, manager = await _ambulance(client, as_role)
    session_id = await start_tracking(client, headers, vehicle_id)
    await send(client, headers, vehicle_id, session_id, packet(1, at=ago(2)))
    event_id = (await _start(client, headers, vehicle_id)).json()["id"]
    r = await client.post(f"{API}/manager/emergency/events/{event_id}/end", headers=manager,
                          json={"note": "Misuse reported"})
    assert r.json()["endReason"] == "MANAGER"

    await _start(client, headers, vehicle_id)
    await client.post(f"{API}/vehicles/{vehicle_id}/tracking/stop", headers=headers)
    events = (await client.get(f"{API}/manager/emergency/events", headers=manager)).json()
    assert events[0]["endReason"] == "TRACKING_STOPPED"


async def test_stale_emergency_expires(client, as_role, session_factory):
    headers, vehicle_id, manager = await _ambulance(client, as_role)
    session_id = await start_tracking(client, headers, vehicle_id)
    await send(client, headers, vehicle_id, session_id, packet(1, at=ago(2)))
    await _start(client, headers, vehicle_id)
    async with session_factory() as db:
        assert await emergency_service.expire(db, utcnow()) == 0
        assert await emergency_service.expire(db, utcnow() + timedelta(seconds=200)) == 1
        await db.commit()
    events = (await client.get(f"{API}/manager/emergency/events", headers=manager)).json()
    assert events[0]["endReason"] == "TIMEOUT"


async def test_reject_then_request_again(client, as_role):
    headers, vehicle_id, manager = await _ambulance(client, as_role, approve=False)
    pending = (await client.get(f"{API}/manager/emergency/authorizations?status=PENDING", headers=manager)).json()
    r = await client.post(f"{API}/manager/emergency/authorizations/{pending[0]['id']}/reject", headers=manager,
                          json={"notes": "Registration number not found"})
    assert r.json()["status"] == "REJECTED"
    r = await client.post(f"{API}/vehicles/{vehicle_id}/emergency/authorization-request", headers=headers)
    assert r.status_code == 200 and r.json()["authorizationStatus"] == "PENDING"
    r = await client.post(f"{API}/vehicles/{vehicle_id}/emergency/authorization-request", headers=headers)
    assert r.status_code == 409 and r.json()["error"]["code"] == "AUTHORIZATION_PENDING"


async def test_authorization_endpoints_are_manager_only(client, as_role):
    headers, _ = await driver_with_vehicle(client, as_role, vehicle_type="POLICE")
    assert (await client.get(f"{API}/manager/emergency/authorizations", headers=headers)).status_code == 403
    assert (await client.get(f"{API}/emergency/active", headers=headers)).status_code == 403


async def test_expired_authorization_is_not_valid(client, as_role):
    headers, vehicle_id = await driver_with_vehicle(client, as_role, vehicle_type="FIRE_TRUCK")
    manager = await as_role(UserRole.MANAGER)
    pending = (await client.get(f"{API}/manager/emergency/authorizations", headers=manager)).json()
    r = await client.post(f"{API}/manager/emergency/authorizations/{pending[0]['id']}/approve", headers=manager,
                          json={"validUntil": (utcnow() - timedelta(days=1)).isoformat()})
    assert r.status_code == 422


async def test_suspending_vehicle_stops_tracking_and_emergency(client, as_role):
    headers, vehicle_id, manager = await _ambulance(client, as_role)
    session_id = await start_tracking(client, headers, vehicle_id)
    await send(client, headers, vehicle_id, session_id, packet(1, at=ago(2)))
    await _start(client, headers, vehicle_id)
    r = await client.patch(f"{API}/manager/vehicles/{vehicle_id}/status", headers=manager,
                           json={"status": "SUSPENDED", "reason": "Suspicious telemetry"})
    assert r.status_code == 200
    assert (await client.get(f"{API}/emergency/active", headers=manager)).json() == []
    r = await send(client, headers, vehicle_id, session_id, packet(2, at=ago(1)))
    assert r.status_code == 409
