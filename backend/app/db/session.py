from collections.abc import AsyncIterator

from sqlalchemy import event
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker, create_async_engine

from app.core.config import get_settings

_settings = get_settings()


def configure_sqlite(async_engine: AsyncEngine) -> None:
    """SQLite quick-start/test mode: WAL and a busy timeout let the API, the engine runner and
    the demo loop write concurrently without "database is locked" errors."""
    if async_engine.dialect.name != "sqlite":
        return

    @event.listens_for(async_engine.sync_engine, "connect")
    def _pragmas(dbapi_connection, _record) -> None:
        cursor = dbapi_connection.cursor()
        cursor.execute("PRAGMA journal_mode=WAL")
        cursor.execute("PRAGMA busy_timeout=15000")
        cursor.execute("PRAGMA foreign_keys=ON")
        cursor.close()


engine = create_async_engine(_settings.database_url, echo=_settings.db_echo, pool_pre_ping=True)
configure_sqlite(engine)
SessionLocal = async_sessionmaker(engine, expire_on_commit=False)


async def get_db() -> AsyncIterator[AsyncSession]:
    """One session per request. Services commit explicitly; anything uncommitted is rolled back."""
    async with SessionLocal() as session:
        yield session


def get_session_factory() -> async_sessionmaker:
    """For code that must open its own short sessions (WebSocket auth, background tasks)."""
    return SessionLocal
