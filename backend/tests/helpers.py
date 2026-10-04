"""Shared helpers for Phase 3+ tests."""
from datetime import datetime, timedelta

from app.core.time import utcnow
from app.models.enums import UserRole
from app.schemas.intersection import ApproachCreate, IntersectionCreate, LinkCreate
from app.services import intersection_service
from tests.conftest import API

LAT, LON0, SPACING = 31.5204, 74.3300, 0.0065  # same placeholder corridor as scripts/seed_intersections
INSTALL = "test-install-0001"


async def seed_corridor(session_factory, n: int = 4, adaptive: bool = False, policy: str | None = None) -> dict[str, str]:
    """I1..In on an east-west line with four approaches each and links both ways.

    policy: AUTO / FIXED / ADAPTIVE; `adaptive=True` is shorthand for ADAPTIVE (default FIXED).
    """
    policy = policy or ("ADAPTIVE" if adaptive else "FIXED")
    from traffic_engine.geo import haversine_m

    ids: dict[str, str] = {}
    async with session_factory() as db:
        nodes = []
        for i in range(n):
            node = await intersection_service.create(db, None, IntersectionCreate(
                code=f"I{i + 1}", name=f"Junction {i + 1}", latitude=LAT, longitude=LON0 + i * SPACING,
                radius_m=40, approach_radius_m=250, controller_type=policy,
            ))
            nodes.append(node)
            ids[node.code] = str(node.id)
        for i, node in enumerate(nodes):
            west = nodes[i - 1] if i > 0 else None
            east = nodes[i + 1] if i + 1 < n else None
            for name, bearing, upstream in (("Eastbound", 90.0, west), ("Westbound", 270.0, east),
                                            ("Northbound", 0.0, None), ("Southbound", 180.0, None)):
                await intersection_service.add_approach(db, None, node.id, ApproachCreate(
                    name=name, travel_bearing_deg=bearing, zone_length_m=200,
                    upstream_intersection_id=upstream.id if upstream else None))
        for a, b in zip(nodes, nodes[1:]):
            d = haversine_m(a.latitude, a.longitude, b.latitude, b.longitude)
            for src, dst, approach in ((a, b, "Eastbound"), (b, a, "Westbound")):
                detail = await intersection_service.get_detail(db, dst.id)
                target = next(x for x in detail.approaches if x.name == approach)
                await intersection_service.add_link(db, None, src.id, LinkCreate(
                    to_intersection_id=dst.id, to_approach_id=target.id, distance_m=d))
    return ids


async def driver_with_vehicle(client, as_role, *, email="driver@example.com", vehicle_type="NORMAL",
                              install=INSTALL) -> tuple[dict, str]:
    headers = await as_role(UserRole.END_USER, email)
    body = {"vehicleType": vehicle_type, "displayName": "Test vehicle"}
    if vehicle_type != "NORMAL":
        body["registrationNumber"] = "EMG-101"
    r = await client.post(f"{API}/vehicles", headers=headers, json=body)
    assert r.status_code == 201, r.text
    vehicle_id = r.json()["id"]
    r = await client.post(f"{API}/vehicles/{vehicle_id}/devices", headers=headers,
                          json={"installationId": install, "platform": "ANDROID"})
    assert r.status_code == 200, r.text
    return headers | {"X-Installation-Id": install}, vehicle_id


async def start_tracking(client, headers, vehicle_id) -> str:
    r = await client.post(f"{API}/vehicles/{vehicle_id}/tracking/start", headers=headers)
    assert r.status_code == 201, r.text
    return r.json()["id"]


def packet(seq: int, *, at: datetime | None = None, lat: float = LAT, lon: float = LON0 - 0.001,
           speed: float | None = 10.0, heading: float | None = 90.0, accuracy: float = 5.0,
           emergency: bool = False, mocked: bool = False) -> dict:
    return {
        "seq": seq, "recordedAt": (at or utcnow()).isoformat(), "lat": lat, "lon": lon, "accuracyM": accuracy,
        "speedMps": speed, "headingDeg": heading, "emergency": emergency, "mocked": mocked,
    }


def ago(seconds: float) -> datetime:
    return utcnow() - timedelta(seconds=seconds)


async def send(client, headers, vehicle_id, session_id, *packets):
    return await client.post(f"{API}/vehicles/{vehicle_id}/telemetry", headers=headers,
                             json={"sessionId": session_id, "packets": list(packets)})
