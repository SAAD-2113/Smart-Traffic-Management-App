import json

from app.models.enums import UserRole
from tests.conftest import API
from tests.helpers import (
    INSTALL,
    LAT,
    LON0,
    ago,
    driver_with_vehicle,
    packet,
    seed_corridor,
    send,
    start_tracking,
)


async def _tracking(client, as_role):
    headers, vehicle_id = await driver_with_vehicle(client, as_role)
    session_id = await start_tracking(client, headers, vehicle_id)
    return headers, vehicle_id, session_id


def statuses(r):
    return [(p["status"], p.get("reason")) for p in r.json()["results"]]


async def test_tracking_requires_the_bound_device(client, as_role):
    headers, vehicle_id = await driver_with_vehicle(client, as_role)
    no_header = {k: v for k, v in headers.items() if k != "X-Installation-Id"}
    r = await client.post(f"{API}/vehicles/{vehicle_id}/tracking/start", headers=no_header)
    assert r.status_code == 400 and r.json()["error"]["code"] == "INSTALLATION_ID_REQUIRED"
    other = no_header | {"X-Installation-Id": "some-other-phone-1"}
    r = await client.post(f"{API}/vehicles/{vehicle_id}/tracking/start", headers=other)
    assert r.status_code == 409 and r.json()["error"]["code"] == "DEVICE_NOT_BOUND"


async def test_valid_packet_updates_live_state(client, as_role):
    headers, vehicle_id, session_id = await _tracking(client, as_role)
    r = await send(client, headers, vehicle_id, session_id, packet(1, at=ago(1)))
    assert r.status_code == 200, r.text
    assert r.json()["accepted"] == 1 and r.json()["results"][0]["live"] is True
    assert r.json()["emergencyActive"] is False

    latest = (await client.get(f"{API}/vehicles/{vehicle_id}/telemetry/latest", headers=headers)).json()
    assert latest["trackingStatus"] == "TRANSMITTING"
    assert latest["live"]["speedMps"] == 10.0 and latest["live"]["gpsQuality"] == "EXCELLENT"
    assert latest["session"]["packetCount"] == 1


async def test_invalid_values_are_rejected_per_packet(client, as_role):
    headers, vehicle_id, session_id = await _tracking(client, as_role)
    r = await send(
        client, headers, vehicle_id, session_id,
        packet(1, at=ago(9), lat=95.0),
        packet(2, at=ago(8), lat=0.0, lon=0.0),
        packet(3, at=ago(7), speed=-1.0),
        packet(4, at=ago(6), speed=90.0),
        packet(5, at=ago(5), heading=360.0),
        packet(6, at=ago(4), accuracy=900.0),
        packet(7, at=ago(3), accuracy=0.0),
        packet(8, at=ago(2)),
    )
    assert r.status_code == 200
    assert statuses(r) == [
        ("REJECTED", "INVALID_COORDINATES"), ("REJECTED", "INVALID_COORDINATES"), ("REJECTED", "INVALID_SPEED"),
        ("REJECTED", "UNREALISTIC_SPEED"), ("REJECTED", "INVALID_HEADING"), ("REJECTED", "LOW_ACCURACY"),
        ("REJECTED", "INVALID_ACCURACY"), ("ACCEPTED", None),
    ]
    assert r.json()["accepted"] == 1 and r.json()["rejected"] == 7


async def test_missing_fields_and_non_finite_numbers_fail_the_request(client, as_role):
    headers, vehicle_id, session_id = await _tracking(client, as_role)
    bad = packet(1)
    del bad["lat"]
    r = await send(client, headers, vehicle_id, session_id, bad)
    assert r.status_code == 422
    body = json.dumps({"sessionId": session_id, "packets": [packet(1)]}).replace('"speedMps": 10.0', '"speedMps": NaN')
    r = await client.post(f"{API}/vehicles/{vehicle_id}/telemetry", headers=headers | {"Content-Type": "application/json"},
                          content=body)
    assert r.status_code == 422
    r = await send(client, headers, vehicle_id, session_id, packet(1) | {"vehicleId": "VH-9999"})
    assert r.status_code == 422  # unknown fields are refused; the vehicle comes from the URL


async def test_timestamps_old_future_and_backfill(client, as_role):
    headers, vehicle_id, session_id = await _tracking(client, as_role)
    r = await send(client, headers, vehicle_id, session_id,
                   packet(1, at=ago(11 * 60)), packet(2, at=ago(-120)))
    assert statuses(r) == [("REJECTED", "STALE_TIMESTAMP"), ("REJECTED", "FUTURE_TIMESTAMP")]

    r = await send(client, headers, vehicle_id, session_id, packet(3, at=ago(40)))  # queued while offline
    assert r.json()["results"][0] == {"seq": 3, "status": "ACCEPTED", "reason": None, "live": False, "usable": True}
    latest = (await client.get(f"{API}/vehicles/{vehicle_id}/telemetry/latest", headers=headers)).json()
    assert latest["live"] is None  # backfill never moves the live state


async def test_replay_order_and_frequency(client, as_role):
    headers, vehicle_id, session_id = await _tracking(client, as_role)
    first = packet(5, at=ago(10))
    assert (await send(client, headers, vehicle_id, session_id, first)).json()["accepted"] == 1
    r = await send(client, headers, vehicle_id, session_id, first)
    assert statuses(r) == [("REJECTED", "DUPLICATE_OR_OUT_OF_ORDER")]
    r = await send(client, headers, vehicle_id, session_id, packet(4, at=ago(9)))
    assert statuses(r) == [("REJECTED", "DUPLICATE_OR_OUT_OF_ORDER")]
    r = await send(client, headers, vehicle_id, session_id, packet(6, at=ago(9.8)))
    assert statuses(r) == [("REJECTED", "TOO_FREQUENT")]


async def test_implausible_jump_then_reanchor(client, as_role):
    headers, vehicle_id, session_id = await _tracking(client, as_role)
    await send(client, headers, vehicle_id, session_id, packet(1, at=ago(10)))
    far = LON0 + 0.2  # ~19 km east, one second later
    r = await send(client, headers, vehicle_id, session_id,
                   packet(2, at=ago(9), lon=far), packet(3, at=ago(8), lon=far),
                   packet(4, at=ago(7), lon=far), packet(5, at=ago(6), lon=far))
    assert statuses(r) == [("REJECTED", "IMPLAUSIBLE_JUMP"), ("REJECTED", "IMPLAUSIBLE_JUMP"),
                           ("ACCEPTED", None), ("ACCEPTED", None)]


async def test_mock_and_poor_accuracy_are_stored_but_not_usable(client, as_role):
    headers, vehicle_id, session_id = await _tracking(client, as_role)
    r = await send(client, headers, vehicle_id, session_id,
                   packet(1, at=ago(3), mocked=True), packet(2, at=ago(2), accuracy=80.0))
    assert [p["usable"] for p in r.json()["results"]] == [False, False]
    latest = (await client.get(f"{API}/vehicles/{vehicle_id}/telemetry/latest", headers=headers)).json()
    assert latest["live"]["gpsQuality"] == "POOR" and latest["live"]["usable"] is False


async def test_ordinary_vehicle_cannot_claim_emergency(client, as_role, session_factory):
    headers, vehicle_id, session_id = await _tracking(client, as_role)
    r = await send(client, headers, vehicle_id, session_id, packet(1, at=ago(1), emergency=True))
    assert r.json()["accepted"] == 1 and r.json()["emergencyActive"] is False
    latest = (await client.get(f"{API}/vehicles/{vehicle_id}/telemetry/latest", headers=headers)).json()
    assert latest["live"]["emergency"] is False


async def test_access_rules(client, as_role):
    headers, vehicle_id, session_id = await _tracking(client, as_role)
    other, _ = await driver_with_vehicle(client, as_role, email="other@example.com", install="other-install-01")
    r = await send(client, other, vehicle_id, session_id, packet(1))
    assert r.status_code == 404
    manager = await as_role(UserRole.MANAGER)
    r = await send(client, manager | {"X-Installation-Id": INSTALL}, vehicle_id, session_id, packet(1))
    assert r.status_code == 403
    r = await send(client, {"X-Installation-Id": INSTALL}, vehicle_id, session_id, packet(1))
    assert r.status_code == 401


async def test_wrong_device_and_closed_session(client, as_role):
    headers, vehicle_id, session_id = await _tracking(client, as_role)
    r = await send(client, headers | {"X-Installation-Id": "stolen-token-phone"}, vehicle_id, session_id, packet(1))
    assert r.status_code == 409 and r.json()["error"]["code"] == "DEVICE_NOT_BOUND"
    assert (await client.post(f"{API}/vehicles/{vehicle_id}/tracking/stop", headers=headers)).status_code == 200
    r = await send(client, headers, vehicle_id, session_id, packet(1))
    assert r.status_code == 409 and r.json()["error"]["code"] == "SESSION_NOT_ACTIVE"


async def test_batch_size_limit(client, as_role):
    headers, vehicle_id, session_id = await _tracking(client, as_role)
    packets = [packet(i, at=ago(300 - i)) for i in range(101)]
    r = await send(client, headers, vehicle_id, session_id, *packets)
    assert r.status_code == 422 and r.json()["error"]["code"] == "BATCH_TOO_LARGE"


async def test_trip_statistics_and_history(client, as_role):
    headers, vehicle_id, session_id = await _tracking(client, as_role)
    packets = [packet(i, at=ago(20 - i), lon=LON0 - 0.01 + i * 0.0001) for i in range(10)]  # ~9.5 m apart
    assert (await send(client, headers, vehicle_id, session_id, *packets)).json()["accepted"] == 10
    await client.post(f"{API}/vehicles/{vehicle_id}/tracking/stop", headers=headers, json={"sessionId": session_id})
    sessions = (await client.get(f"{API}/vehicles/{vehicle_id}/tracking/sessions", headers=headers)).json()
    trip = sessions[0]
    assert trip["endReason"] == "USER" and trip["packetCount"] == 10
    assert 80 < trip["distanceM"] < 90
    assert trip["maxSpeedMps"] == 10.0


async def test_restart_closes_previous_session(client, as_role):
    headers, vehicle_id, first = await _tracking(client, as_role)
    second = await start_tracking(client, headers, vehicle_id)
    sessions = (await client.get(f"{API}/vehicles/{vehicle_id}/tracking/sessions", headers=headers)).json()
    by_id = {s["id"]: s for s in sessions}
    assert by_id[first]["endReason"] == "RESTARTED" and by_id[second]["endedAt"] is None


async def test_packet_is_mapped_to_intersection_approach(client, as_role, session_factory):
    await seed_corridor(session_factory)
    headers, vehicle_id, session_id = await _tracking(client, as_role)
    # 100 m west of I1, heading east
    r = await send(client, headers, vehicle_id, session_id, packet(1, at=ago(1), lat=LAT, lon=LON0 - 0.00105))
    assert r.json()["accepted"] == 1
    live = (await client.get(f"{API}/vehicles/{vehicle_id}/telemetry/latest", headers=headers)).json()["live"]
    assert (live["intersectionCode"], live["approachName"], live["zone"]) == ("I1", "Eastbound", "APPROACH")
