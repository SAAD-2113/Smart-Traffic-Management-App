"""Digital V2I relay over a real WebSocket (Starlette TestClient)."""
import contextlib
import json

import pytest
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine
from starlette.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from app.db.base import Base
from app.db.session import get_db, get_session_factory
from app.main import app
from app.models.enums import UserRole
from app.realtime.v2i_relay import relay
from app.services import auth_service
from tests.conftest import API, PASSWORD

USERS = [("host@example.com", UserRole.ADMIN), ("car@example.com", UserRole.END_USER),
         ("amb@example.com", UserRole.END_USER), ("stranger@example.com", UserRole.END_USER),
         ("mgr@example.com", UserRole.MANAGER)]


@pytest.fixture
def tc(tmp_path):
    engine = create_async_engine(f"sqlite+aiosqlite:///{tmp_path / 'v2i.db'}")
    factory = async_sessionmaker(engine, expire_on_commit=False)

    async def _get_db():
        async with factory() as session:
            yield session

    async def _setup():
        async with engine.begin() as conn:
            await conn.run_sync(Base.metadata.create_all)
        for email, role in USERS:
            async with factory() as db:
                await auth_service.create_user(db, email=email, password=PASSWORD, full_name="U", role=role)

    relay.reset()
    app.dependency_overrides[get_db] = _get_db
    app.dependency_overrides[get_session_factory] = lambda: factory
    with TestClient(app) as c:
        c.portal.call(_setup)
        yield c
        c.portal.call(engine.dispose)
    app.dependency_overrides.clear()
    relay.reset()


def _token(tc, email):
    return tc.post(f"{API}/auth/login", json={"email": email, "password": PASSWORD}).json()["accessToken"]


def _h(token):
    return {"Authorization": f"Bearer {token}"}


@pytest.fixture
def session(tc):
    """An open session hosted by the admin; car and amb joined; amb is an approved emergency."""
    host = _token(tc, "host@example.com")
    s = tc.post(f"{API}/v2i/sessions", headers=_h(host), json={"name": "Gate", "centerLat": 31.5, "centerLon": 74.3}).json()
    tokens = {"host": host}
    for name in ("car", "amb"):
        tokens[name] = _token(tc, f"{name}@example.com")
        assert tc.post(f"{API}/v2i/join", headers=_h(tokens[name]), json={"joinCode": s["joinCode"]}).status_code == 200
    r = tc.put(f"{API}/v2i/profiles/emergency", headers=_h(host), json={"email": "amb@example.com", "status": "APPROVED"})
    assert r.status_code == 200
    tokens["stranger"] = _token(tc, "stranger@example.com")
    tokens["mgr"] = _token(tc, "mgr@example.com")
    return s, tokens


@pytest.fixture
def sockets():
    """Opened sockets are closed at the end of the test, also when it fails."""
    with contextlib.ExitStack() as stack:
        yield stack


def _connect(stack, tc, token, session_id):
    ws = tc.websocket_connect(f"{API}/v2i/ws")
    conn = stack.enter_context(ws)
    conn.send_json({"type": "auth", "accessToken": token, "sessionId": session_id})
    return ws, conn


def _pos(vid, seq=1, ty=0, **kw):
    d = {"t": "pos", "id": vid, "ty": ty, "lat": 31.4997, "lon": 74.3, "spd": 0.0, "hdg": 0, "seq": seq, "hw": "phone"}
    d.update(kw)
    return json.dumps(d, separators=(",", ":"))


def test_roles_come_from_the_server(tc, session, sockets):
    s, t = session
    ws, i = _connect(sockets, tc, t["host"], s["id"])
    hello = i.receive_json()
    assert hello["k"] == "hello" and hello["as"] == "intersection" and hello["vid"] is None
    assert hello["session"]["centerLat"] == 31.5
    assert i.receive_json() == {"k": "members", "vehicles": []}
    ws2, v = _connect(sockets, tc, t["car"], s["id"])
    hv = v.receive_json()
    assert hv["as"] == "vehicle" and hv["vid"] == 1001 and hv["emergency"] is False and hv["intersectionOnline"] is True
    assert i.receive_json() == {"k": "member", "vid": 1001, "online": True, "emergency": False}
    v.close()
    assert i.receive_json() == {"k": "member", "vid": 1001, "online": False, "emergency": False}


@pytest.mark.parametrize("who,code", [("stranger", 4403), ("mgr", 4403)])
def test_non_members_are_refused(tc, session, sockets, who, code):
    s, t = session
    ws, c = _connect(sockets, tc, t[who], s["id"])
    with pytest.raises(WebSocketDisconnect) as e:
        c.receive_json()
    assert e.value.code == code


def test_bad_auth_is_refused(tc, session, sockets):
    s, _ = session
    ws, c = _connect(sockets, tc, "not-a-token", s["id"])
    with pytest.raises(WebSocketDisconnect) as e:
        c.receive_json()
    assert e.value.code == 4401


def test_pos_ack_round_trip_and_privacy(tc, session, sockets):
    s, t = session
    wi, i = _connect(sockets, tc, t["host"], s["id"])
    i.receive_json(), i.receive_json()
    wc, car = _connect(sockets, tc, t["car"], s["id"])
    car.receive_json()
    wa, amb = _connect(sockets, tc, t["amb"], s["id"])
    assert amb.receive_json()["emergency"] is True
    assert i.receive_json()["vid"] == 1001
    assert i.receive_json() == {"k": "member", "vid": 1002, "online": True, "emergency": True}

    raw = _pos(1001)
    car.send_json({"k": "pos", "raw": raw})
    fwd = i.receive_json()
    assert fwd == {"k": "pos", "vid": 1001, "raw": raw}, "forwarded unchanged"
    ack = '{"t":"ack","id":1001,"seq":1,"mode":"fixed","lane":"S","st":"QUEUED","sig":"R","rem":67.0,"pri":0}'
    i.send_json({"k": "ack", "to": 1001, "raw": ack})
    assert car.receive_json() == {"k": "ack", "raw": ack}

    # an emergency packet from the authorised account passes; the car's is refused
    amb.send_json({"k": "pos", "raw": _pos(1002, ty=1)})
    assert i.receive_json()["vid"] == 1002
    car.send_json({"k": "pos", "raw": _pos(1001, seq=2, ty=1)})
    assert car.receive_json()["code"] == "EMERGENCY_NOT_AUTHORIZED"
    # a vehicle cannot use another vehicle's id
    car.send_json({"k": "pos", "raw": _pos(1002, seq=3)})
    assert car.receive_json()["code"] == "WRONG_VEHICLE_ID"
    # a vehicle cannot send ACKs or states
    car.send_json({"k": "ack", "to": 1002, "raw": ack})
    assert car.receive_json()["code"] == "BAD_MESSAGE"
    # the ACK for 1001 never reaches 1002; RTT reports go to the intersection
    i.send_json({"k": "ack", "to": 1001, "raw": ack})
    assert car.receive_json()["k"] == "ack"
    amb.send_json({"k": "rtt", "ms": 87})
    assert i.receive_json() == {"k": "rtt", "vid": 1002, "ms": 87}
    amb.send_json({"k": "ping"})
    assert amb.receive_json()["k"] == "pong", "amb received nothing else"

    # state: kept for the host, never sent to vehicles
    i.send_json({"k": "state", "raw": json.dumps({"v": 2, "t": "state", "mode": "fixed", "vehicles": []})})
    i.send_json({"k": "ping"})
    assert i.receive_json()["k"] == "pong"
    st = tc.get(f"{API}/v2i/sessions/{s['id']}/state", headers=_h(t["host"])).json()
    assert st["intersectionOnline"] is True and st["state"]["mode"] == "fixed"


def test_revoking_emergency_applies_to_the_open_connection(tc, session, sockets):
    s, t = session
    wi, i = _connect(sockets, tc, t["host"], s["id"])
    i.receive_json(), i.receive_json()
    wa, amb = _connect(sockets, tc, t["amb"], s["id"])
    amb.receive_json(), i.receive_json()
    r = tc.put(f"{API}/v2i/profiles/emergency", headers=_h(t["host"]), json={"email": "amb@example.com", "status": "REVOKED"})
    assert r.status_code == 200
    assert amb.receive_json() == {"k": "profile", "emergency": False}
    assert i.receive_json() == {"k": "member", "vid": 1002, "online": True, "emergency": False}
    amb.send_json({"k": "pos", "raw": _pos(1002, ty=1)})
    assert amb.receive_json()["code"] == "EMERGENCY_NOT_AUTHORIZED"


def test_intersection_offline_and_session_close(tc, session, sockets):
    s, t = session
    wc, car = _connect(sockets, tc, t["car"], s["id"])
    assert car.receive_json()["intersectionOnline"] is False
    car.send_json({"k": "pos", "raw": _pos(1001)})
    assert car.receive_json()["code"] == "INTERSECTION_OFFLINE"
    wi, i = _connect(sockets, tc, t["host"], s["id"])
    i.receive_json()
    assert i.receive_json() == {"k": "members", "vehicles": [{"vid": 1001, "emergency": False}]}
    assert car.receive_json() == {"k": "intersection", "online": True}
    tc.post(f"{API}/v2i/sessions/{s['id']}/close", headers=_h(t["host"]))
    with pytest.raises(WebSocketDisconnect) as e:
        car.receive_json()
    assert e.value.code == 4410


def test_rate_limit(tc, session, sockets):
    s, t = session
    wi, i = _connect(sockets, tc, t["host"], s["id"])
    i.receive_json(), i.receive_json()
    wc, car = _connect(sockets, tc, t["car"], s["id"])
    car.receive_json(), i.receive_json()
    for n in range(12):  # burst of 10 allowed at most
        car.send_json({"k": "pos", "raw": _pos(1001, seq=n)})
    for _ in range(10):
        assert i.receive_json()["k"] == "pos"
    assert car.receive_json()["code"] == "RATE_LIMITED"
