"""Hosted deployment helpers: provider database URLs and first-start bootstrap."""
import pytest

from app.core.config import Settings
from scripts.bootstrap import BootstrapError, bootstrap
from tests.conftest import API

ADMIN_ENV = {"BOOTSTRAP_ADMIN_EMAIL": "Owner@Example.com", "BOOTSTRAP_ADMIN_PASSWORD": "CloudDemo2026"}


@pytest.mark.parametrize(
    ("given", "expected"),
    [
        ("postgres://u:p%40ss@db.example.com:5432/app", "postgresql+asyncpg://u:p%40ss@db.example.com:5432/app"),
        ("postgresql://u:pw@host/db", "postgresql+asyncpg://u:pw@host/db"),
        (
            "postgresql://u:pw@ep-x.neon.tech/neondb?sslmode=require&channel_binding=require",
            "postgresql+asyncpg://u:pw@ep-x.neon.tech/neondb?ssl=require",
        ),
        ("postgresql+asyncpg://u:pw@host/db?ssl=require", "postgresql+asyncpg://u:pw@host/db?ssl=require"),
        ("sqlite+aiosqlite:///./smart_traffic.db", "sqlite+aiosqlite:///./smart_traffic.db"),
    ],
)
def test_provider_database_urls_use_asyncpg(given, expected):
    assert Settings(database_url=given).database_url == expected


async def test_bootstrap_creates_admin_and_corridor_once(session_factory, client):
    env = {**ADMIN_ENV, "SEED_CORRIDOR": "auto"}
    async with session_factory() as db:
        assert await bootstrap(db, env) == ["created admin owner@example.com", "seeded corridor I1-I4 (AUTO)"]
    async with session_factory() as db:
        assert await bootstrap(db, env) == [
            "admin owner@example.com already exists (unchanged)",
            "corridor I1-I4 already present (unchanged)",
        ]

    login = await client.post(f"{API}/auth/login", json={"email": "owner@example.com", "password": "CloudDemo2026"})
    assert login.status_code == 200
    assert login.json()["user"]["role"] == "ADMIN"
    token = login.json()["accessToken"]
    nodes = (await client.get(f"{API}/intersections", headers={"Authorization": f"Bearer {token}"})).json()
    assert sorted(n["code"] for n in nodes) == ["I1", "I2", "I3", "I4"]
    assert {n["controllerType"] for n in nodes} == {"AUTO"}


async def test_bootstrap_does_nothing_without_settings(session_factory):
    async with session_factory() as db:
        assert await bootstrap(db, {}) == []


@pytest.mark.parametrize(
    "env",
    [
        {"BOOTSTRAP_ADMIN_EMAIL": "owner@example.com"},
        {"BOOTSTRAP_ADMIN_EMAIL": "not-an-email", "BOOTSTRAP_ADMIN_PASSWORD": "CloudDemo2026"},
        {"BOOTSTRAP_ADMIN_EMAIL": "owner@example.com", "BOOTSTRAP_ADMIN_PASSWORD": "short1"},
        {"SEED_CORRIDOR": "yes"},
    ],
)
async def test_bootstrap_rejects_bad_settings(session_factory, env):
    async with session_factory() as db:
        with pytest.raises(BootstrapError):
            await bootstrap(db, env)
