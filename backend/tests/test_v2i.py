"""Digital V2I REST: roles from the database, vehicle ids, emergency authorisation, sessions."""
import json

import pytest

from app.models.enums import UserRole
from app.services import v2i_packets
from app.services.v2i_packets import PacketError
from tests.conftest import API


async def test_me_follows_the_stored_role(as_role, client):
    driver = await as_role(UserRole.END_USER)
    manager = await as_role(UserRole.MANAGER)
    admin = await as_role(UserRole.ADMIN)
    d = (await client.get(f"{API}/v2i/me", headers=driver)).json()
    assert d["role"] == "END_USER" and d["canDrive"] and not d["canHost"]
    assert d["vehicleId"] == 1001 and d["emergencyStatus"] == "NONE" and d["emergency"] is False
    assert (await client.get(f"{API}/v2i/me", headers=driver)).json()["vehicleId"] == 1001, "assigned once"
    m = (await client.get(f"{API}/v2i/me", headers=manager)).json()
    assert m["canHost"] and not m["canDrive"] and m["vehicleId"] is None
    assert (await client.get(f"{API}/v2i/me", headers=admin)).json()["canHost"]


async def test_vehicle_ids_are_assigned_by_the_server_from_1001(create_user, login, client):
    ids = []
    for i in range(3):
        await create_user(f"d{i}@example.com")
        headers, _ = await login(f"d{i}@example.com")
        ids.append((await client.get(f"{API}/v2i/me", headers=headers)).json()["vehicleId"])
    assert ids == [1001, 1002, 1003]


async def test_role_cannot_be_chosen_by_the_client(as_role, client):
    driver = await as_role(UserRole.END_USER)
    r = await client.post(f"{API}/v2i/sessions", headers=driver, json={"name": "x", "centerLat": 31.5, "centerLon": 74.3})
    assert r.status_code == 403
    r = await client.post(f"{API}/v2i/me/emergency-request", headers=driver, json={"reason": "x", "role": "ADMIN"})
    assert r.status_code == 422, "unknown fields are rejected"


async def test_emergency_is_requested_by_the_user_and_set_by_an_admin(as_role, client):
    driver = await as_role(UserRole.END_USER, "amb@example.com")
    admin = await as_role(UserRole.ADMIN)
    manager = await as_role(UserRole.MANAGER)
    r = await client.post(f"{API}/v2i/me/emergency-request", headers=driver, json={"reason": "Rescue 1122 unit"})
    assert r.status_code == 200 and r.json()["emergencyStatus"] == "REQUESTED" and r.json()["emergency"] is False
    assert (await client.post(f"{API}/v2i/me/emergency-request", headers=driver, json={})).status_code == 409

    listed = (await client.get(f"{API}/v2i/profiles?emergencyStatus=REQUESTED", headers=admin)).json()
    assert [p["email"] for p in listed] == ["amb@example.com"] and listed[0]["emergencyReason"] == "Rescue 1122 unit"
    assert (await client.get(f"{API}/v2i/profiles", headers=manager)).status_code == 403
    body = {"email": "amb@example.com", "status": "APPROVED"}
    assert (await client.put(f"{API}/v2i/profiles/emergency", headers=manager, json=body)).status_code == 403
    assert (await client.put(f"{API}/v2i/profiles/emergency", headers=driver, json=body)).status_code == 403
    r = await client.put(f"{API}/v2i/profiles/emergency", headers=admin, json=body)
    assert r.status_code == 200 and r.json()["emergencyStatus"] == "APPROVED"
    assert (await client.get(f"{API}/v2i/me", headers=driver)).json()["emergency"] is True
    r = await client.put(f"{API}/v2i/profiles/emergency", headers=admin, json={"email": "amb@example.com", "status": "REQUESTED"})
    assert r.status_code == 422
    r = await client.put(f"{API}/v2i/profiles/emergency", headers=admin, json={"email": "manager@example.com", "status": "APPROVED"})
    assert r.status_code == 409, "only driver accounts can be emergency vehicles"


async def test_admin_can_set_emergency_on_an_account_that_never_asked(create_user, as_role, client, login):
    await create_user("fire@example.com")
    admin = await as_role(UserRole.ADMIN)
    r = await client.put(f"{API}/v2i/profiles/emergency", headers=admin, json={"email": "fire@example.com", "status": "APPROVED"})
    assert r.status_code == 200 and r.json()["vehicleId"] == 1001
    headers, _ = await login("fire@example.com")
    assert (await client.get(f"{API}/v2i/me", headers=headers)).json()["emergency"] is True


async def test_sessions_join_code_and_close(as_role, client):
    host = await as_role(UserRole.ADMIN)
    driver = await as_role(UserRole.END_USER)
    other = await as_role(UserRole.MANAGER)
    r = await client.post(f"{API}/v2i/sessions", headers=host, json={"name": "Campus gate", "centerLat": 31.5, "centerLon": 74.3})
    assert r.status_code == 201
    s = r.json()
    code = s["joinCode"]
    assert len(code) == 6 and set(code) <= set("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    r = await client.post(f"{API}/v2i/sessions", headers=host, json={"name": "second", "centerLat": 0, "centerLon": 0})
    assert r.status_code == 409 and r.json()["error"]["details"][0]["sessionId"] == s["id"]

    assert (await client.post(f"{API}/v2i/join", headers=driver, json={"joinCode": "ZZZZZZ"})).status_code == 404
    j = (await client.post(f"{API}/v2i/join", headers=driver, json={"joinCode": code.lower()})).json()
    assert j["sessionId"] == s["id"] and j["vehicleId"] == 1001 and "joinCode" not in j
    assert (await client.post(f"{API}/v2i/join", headers=host, json={"joinCode": code})).status_code == 403
    assert [x["sessionId"] for x in (await client.get(f"{API}/v2i/joined", headers=driver)).json()] == [s["id"]]
    mine = (await client.get(f"{API}/v2i/sessions/mine", headers=host)).json()
    assert [x["id"] for x in mine] == [s["id"]] and mine[0]["members"] == 1

    # another manager cannot see or close it; vehicles cannot read the intersection state
    assert (await client.get(f"{API}/v2i/sessions/{s['id']}", headers=other)).status_code == 404
    assert (await client.post(f"{API}/v2i/sessions/{s['id']}/close", headers=other)).status_code == 404
    assert (await client.get(f"{API}/v2i/sessions/{s['id']}/state", headers=driver)).status_code == 403
    state = (await client.get(f"{API}/v2i/sessions/{s['id']}/state", headers=host)).json()
    assert state["intersectionOnline"] is False and state["state"] is None

    r = await client.post(f"{API}/v2i/sessions/{s['id']}/close", headers=host)
    assert r.json()["status"] == "CLOSED"
    assert (await client.post(f"{API}/v2i/join", headers=driver, json={"joinCode": code})).status_code == 404
    assert (await client.get(f"{API}/v2i/joined", headers=driver)).json() == []


def _pos(**kw):
    d = {"t": "pos", "id": 1001, "ty": 0, "lat": 31.5, "lon": 74.3, "spd": 12.0, "hdg": 180, "seq": 1, "hw": "Pixel 8"}
    d.update(kw)
    return json.dumps(d, separators=(",", ":"))


def test_pos_validation_mirrors_the_firmware_limits():
    assert v2i_packets.validate_pos(_pos(), 1001, False)["id"] == 1001
    assert v2i_packets.validate_pos(_pos(ty=1), 1001, True)["ty"] == 1
    assert v2i_packets.validate_pos(_pos(tl="N", rssi=-60), 1001, False)
    no_hdg = json.loads(_pos())
    del no_hdg["hdg"]
    assert v2i_packets.validate_pos(json.dumps(no_hdg), 1001, False)
    for raw, code in [
        (_pos(id=1002), "WRONG_VEHICLE_ID"),
        (_pos(ty=1), "EMERGENCY_NOT_AUTHORIZED"),
        (_pos(ty=2), "BAD_PACKET"),
        (_pos(lat=91), "BAD_PACKET"),
        (_pos(hdg=360), "BAD_PACKET"),
        (_pos(hdg=1.5), "BAD_PACKET"),
        (_pos(spd=-1), "BAD_PACKET"),
        (_pos(hw="x" * 12), "BAD_PACKET"),
        (_pos(tl="X"), "BAD_PACKET"),
        (_pos(seq=-1), "BAD_PACKET"),
        (_pos(extra=1), "BAD_PACKET"),
        (_pos(hw="x" * 11, tl="N", rssi=-100, lat=-31.123456, lon=-174.123456) + " " * 80, "PACKET_TOO_LONG"),
        ("not json", "BAD_PACKET"),
        ('{"t":"ack"}', "BAD_PACKET"),
    ]:
        with pytest.raises(PacketError) as e:
            v2i_packets.validate_pos(raw, 1001, False)
        assert e.value.code == code, raw


def test_ack_and_state_validation():
    ack = '{"t":"ack","id":1001,"seq":7,"mode":"fixed","lane":"S","st":"QUEUED","sig":"R","rem":67.0,"pri":0}'
    assert v2i_packets.validate_ack(ack, 1001)["sig"] == "R"
    none = '{"t":"ack","id":1001,"seq":7,"mode":"adaptive","lane":"-","st":"IGNORED","sig":"-","rem":0,"pri":0}'
    assert v2i_packets.validate_ack(none, 1001)["lane"] == "-"
    with pytest.raises(PacketError):
        v2i_packets.validate_ack(ack, 1002)
    with pytest.raises(PacketError):
        v2i_packets.validate_ack(ack.replace('"pri":0', '"pri":true'), 1001)
    assert v2i_packets.validate_state('{"v":2,"t":"state","mode":"fixed"}')["mode"] == "fixed"
    with pytest.raises(PacketError):
        v2i_packets.validate_state('{"v":1,"t":"state"}')


async def test_trip_points_for_replay_are_the_owners_only(client, as_role, session_factory):
    from tests.helpers import ago, driver_with_vehicle, packet, send, start_tracking

    headers, vehicle_id = await driver_with_vehicle(client, as_role)
    trip = await start_tracking(client, headers, vehicle_id)
    r = await send(client, headers, vehicle_id, trip,
                   packet(1, at=ago(4), speed=10.0, heading=90.0),
                   packet(2, at=ago(3), lon=74.0, speed=None, heading=None),
                   packet(3, at=ago(2), speed=5.0))
    assert r.status_code == 200, r.text
    points = (await client.get(f"{API}/vehicles/{vehicle_id}/tracking/sessions/{trip}/points", headers=headers)).json()
    assert len(points) == r.json()["accepted"]
    assert points[0]["t"] == 0 and points[0]["speedKmh"] == pytest.approx(36.0) and points[0]["headingDeg"] == 90.0
    assert all(b["t"] > a["t"] for a, b in zip(points, points[1:]))

    other, _ = await driver_with_vehicle(client, as_role, email="other@example.com", install="other-install-0001")
    r = await client.get(f"{API}/vehicles/{vehicle_id}/tracking/sessions/{trip}/points", headers=other)
    assert r.status_code == 404


async def test_export_server_copy_for_the_host_only(as_role, client):
    host = await as_role(UserRole.ADMIN)
    other = await as_role(UserRole.MANAGER)
    driver = await as_role(UserRole.END_USER)
    s = (await client.post(f"{API}/v2i/sessions", headers=host, json={"name": "G", "centerLat": 31.5, "centerLon": 74.3})).json()
    body = {"filename": "v2i_G_20261122-1030_metrics.csv", "contentType": "text/csv",
            "content": "# digital simulation, measured on Pixel 8 on 2026-11-22 10:30\nmetric,scope,value\n"}
    r = await client.post(f"{API}/v2i/sessions/{s['id']}/exports", headers=host, json=body)
    assert r.status_code == 201 and r.json()["size"] == len(body["content"].encode())
    export_id = r.json()["id"]
    assert (await client.post(f"{API}/v2i/sessions/{s['id']}/exports", headers=other, json=body)).status_code == 404
    assert (await client.post(f"{API}/v2i/sessions/{s['id']}/exports", headers=driver, json=body)).status_code == 403
    bad = dict(body, filename="../../etc/passwd")
    assert (await client.post(f"{API}/v2i/sessions/{s['id']}/exports", headers=host, json=bad)).status_code == 422
    listed = (await client.get(f"{API}/v2i/sessions/{s['id']}/exports", headers=host)).json()
    assert [x["filename"] for x in listed] == [body["filename"]]
    d = await client.get(f"{API}/v2i/exports/{export_id}", headers=host)
    assert d.status_code == 200 and d.text == body["content"]
    assert 'attachment; filename="v2i_G_20261122-1030_metrics.csv"' == d.headers["content-disposition"]
    assert (await client.get(f"{API}/v2i/exports/{export_id}", headers=other)).status_code == 404
