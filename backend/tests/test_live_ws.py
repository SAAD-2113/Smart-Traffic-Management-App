"""WebSocket tests use Starlette's TestClient, which runs the app in its own event loop."""
import pytest
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine
from starlette.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from app.db.base import Base
from app.db.session import get_db, get_session_factory
from app.main import app
from app.models.enums import UserRole
from app.realtime.hub import hub
from app.services import auth_service
from app.services.runner import runner
from tests.conftest import API, PASSWORD


@pytest.fixture
def ws_client(tmp_path):
    engine = create_async_engine(f"sqlite+aiosqlite:///{tmp_path / 'ws.db'}")
    factory = async_sessionmaker(engine, expire_on_commit=False)

    async def _get_db():
        async with factory() as session:
            yield session

    async def _setup():
        async with engine.begin() as conn:
            await conn.run_sync(Base.metadata.create_all)
        async with factory() as db:
            await auth_service.create_user(db, email="m@example.com", password=PASSWORD, full_name="M",
                                           role=UserRole.MANAGER)
        async with factory() as db:
            await auth_service.create_user(db, email="d@example.com", password=PASSWORD, full_name="D",
                                           role=UserRole.END_USER)

    app.dependency_overrides[get_db] = _get_db
    app.dependency_overrides[get_session_factory] = lambda: factory
    with TestClient(app) as tc:
        tc.portal.call(_setup)
        tc.factory = factory
        yield tc
        tc.portal.call(engine.dispose)
    app.dependency_overrides.clear()


def _token(tc, email):
    return tc.post(f"{API}/auth/login", json={"email": email, "password": PASSWORD}).json()["accessToken"]


def test_ws_requires_auth_message(ws_client):
    with ws_client.websocket_connect(f"{API}/live/ws") as ws:
        ws.send_json({"type": "hello"})
        with pytest.raises(WebSocketDisconnect) as exc:
            ws.receive_json()
        assert exc.value.code == 4401


def test_ws_rejects_end_users(ws_client):
    with ws_client.websocket_connect(f"{API}/live/ws") as ws:
        ws.send_json({"type": "auth", "accessToken": _token(ws_client, "d@example.com")})
        with pytest.raises(WebSocketDisconnect) as exc:
            ws.receive_json()
        assert exc.value.code == 4403


def test_ws_manager_receives_snapshot(ws_client):
    with ws_client.websocket_connect(f"{API}/live/ws") as ws:
        ws.send_json({"type": "auth", "accessToken": _token(ws_client, "m@example.com")})
        hello = ws.receive_json()
        assert hello["type"] == "hello" and hello["role"] == "MANAGER"
        assert hub.client_count == 1
        ws_client.portal.call(runner.run_cycle, ws_client.factory)
        snapshot = ws.receive_json()
        assert snapshot["type"] == "snapshot"
        assert set(snapshot) >= {"summary", "vehicles", "intersections", "emergencies", "serverTime"}
        assert snapshot["summary"]["system"]["websocketClients"] == 1
        ws.send_json({"type": "ping"})
        assert ws.receive_json()["type"] == "pong"
