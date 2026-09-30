"""Test setup: every test gets a fresh SQLite database, so tests need no running PostgreSQL."""
import os

# Must be set before the app is imported (settings are read at import time).
os.environ["ENVIRONMENT"] = "test"
os.environ["DATABASE_URL"] = "sqlite+aiosqlite://"
os.environ["JWT_SECRET"] = "test-secret-that-is-long-enough-for-hs256-signing"
os.environ["RATE_LIMIT_ENABLED"] = "false"
os.environ["MAX_VEHICLES_PER_USER"] = "3"

import httpx  # noqa: E402
import pytest  # noqa: E402
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine  # noqa: E402

from app import models  # noqa: E402,F401
from app.db.base import Base  # noqa: E402
from app.db.session import get_db  # noqa: E402
from app.main import app as fastapi_app  # noqa: E402
from app.models.enums import UserRole  # noqa: E402
from app.services import auth_service  # noqa: E402

API = "/api/v1"
PASSWORD = "Str0ngPassw0rd"


@pytest.fixture
async def session_factory(tmp_path):
    engine = create_async_engine(f"sqlite+aiosqlite:///{tmp_path / 'test.db'}")
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    yield async_sessionmaker(engine, expire_on_commit=False)
    await engine.dispose()


@pytest.fixture
async def client(session_factory):
    async def _get_db():
        async with session_factory() as session:
            yield session

    fastapi_app.dependency_overrides[get_db] = _get_db
    transport = httpx.ASGITransport(app=fastapi_app)
    async with httpx.AsyncClient(transport=transport, base_url="http://test") as c:
        yield c
    fastapi_app.dependency_overrides.clear()


@pytest.fixture
def create_user(session_factory):
    async def _create(email: str, role: UserRole = UserRole.END_USER, password: str = PASSWORD):
        async with session_factory() as db:
            return await auth_service.create_user(
                db, email=email, password=password, full_name="Test User", role=role
            )

    return _create


@pytest.fixture
def login(client):
    async def _login(email: str, password: str = PASSWORD) -> tuple[dict, dict]:
        response = await client.post(f"{API}/auth/login", json={"email": email, "password": password})
        assert response.status_code == 200, response.text
        body = response.json()
        return {"Authorization": f"Bearer {body['accessToken']}"}, body

    return _login


@pytest.fixture
def as_role(create_user, login):
    """Create a user with the given role and return auth headers for them."""

    async def _as(role: UserRole, email: str | None = None) -> dict:
        email = email or f"{role.value.lower()}@example.com"
        await create_user(email, role)
        headers, _ = await login(email)
        return headers

    return _as
