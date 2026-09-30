from app.models.enums import UserRole
from tests.conftest import API

I5 = {"code": "I5", "name": "Test Junction", "latitude": 31.52, "longitude": 74.35,
      "radiusM": 40, "approachRadiusM": 250}


async def _create(client, headers, **overrides):
    return await client.post(f"{API}/intersections", headers=headers, json=I5 | overrides)


async def test_create_and_read_intersection(client, as_role):
    manager = await as_role(UserRole.MANAGER)
    r = await _create(client, manager)
    assert r.status_code == 201, r.text
    detail = (await client.get(f"{API}/intersections/{r.json()['id']}", headers=manager)).json()
    assert detail["code"] == "I5" and detail["approaches"] == [] and detail["outgoingLinks"] == []


async def test_duplicate_code_rejected(client, as_role):
    manager = await as_role(UserRole.MANAGER)
    await _create(client, manager)
    r = await _create(client, manager, name="Another")
    assert r.status_code == 409 and r.json()["error"]["code"] == "INTERSECTION_CODE_EXISTS"


async def test_geometry_validation(client, as_role):
    manager = await as_role(UserRole.MANAGER)
    assert (await _create(client, manager, approachRadiusM=30)).status_code == 422
    assert (await _create(client, manager, latitude=95)).status_code == 422

    iid = (await _create(client, manager)).json()["id"]
    r = await client.patch(f"{API}/intersections/{iid}", headers=manager, json={"radiusM": 300})
    assert r.status_code == 422 and r.json()["error"]["code"] == "INVALID_GEOMETRY"


async def test_code_is_immutable(client, as_role):
    manager = await as_role(UserRole.MANAGER)
    iid = (await _create(client, manager)).json()["id"]
    r = await client.patch(f"{API}/intersections/{iid}", headers=manager, json={"code": "I9"})
    assert r.status_code == 422


async def test_approaches_and_links(client, as_role):
    manager = await as_role(UserRole.MANAGER)
    a = (await _create(client, manager)).json()["id"]
    b = (await _create(client, manager, code="I6", longitude=74.356)).json()["id"]

    approach = await client.post(f"{API}/intersections/{b}/approaches", headers=manager, json={
        "name": "Eastbound", "travelBearingDeg": 90, "zoneLengthM": 200, "upstreamIntersectionId": a})
    assert approach.status_code == 201
    dup = await client.post(f"{API}/intersections/{b}/approaches", headers=manager, json={
        "name": "Eastbound", "travelBearingDeg": 90, "zoneLengthM": 200})
    assert dup.status_code == 409

    link = await client.post(f"{API}/intersections/{a}/links", headers=manager, json={
        "toIntersectionId": b, "toApproachId": approach.json()["id"], "distanceM": 570})
    assert link.status_code == 201

    self_link = await client.post(f"{API}/intersections/{a}/links", headers=manager, json={
        "toIntersectionId": a, "distanceM": 10})
    assert self_link.status_code == 422

    # An approach that belongs to a different intersection is rejected.
    wrong = await client.post(f"{API}/intersections/{b}/links", headers=manager, json={
        "toIntersectionId": a, "toApproachId": approach.json()["id"], "distanceM": 570})
    assert wrong.status_code == 422

    detail = (await client.get(f"{API}/intersections/{a}", headers=manager)).json()
    assert len(detail["outgoingLinks"]) == 1


async def test_delete_is_soft(client, as_role):
    manager = await as_role(UserRole.MANAGER)
    iid = (await _create(client, manager)).json()["id"]
    assert (await client.delete(f"{API}/intersections/{iid}", headers=manager)).status_code == 204
    detail = (await client.get(f"{API}/intersections/{iid}", headers=manager)).json()
    assert detail["status"] == "INACTIVE"
