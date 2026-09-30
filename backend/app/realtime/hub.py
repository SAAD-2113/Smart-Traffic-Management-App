"""In-process WebSocket hub for manager dashboards.

Snapshots are broadcast after each engine cycle; events (emergency started/ended, new
authorisation request) are broadcast right after the database transaction that caused them
commits, so a client never hears about something that was rolled back.
Single process only; scaling out would need a shared broker (see ADR 0002).
"""
import asyncio
import logging
from dataclasses import dataclass
from datetime import datetime
from typing import Any

from fastapi import WebSocket
from sqlalchemy import event
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import Session

from app.core.time import utcnow

logger = logging.getLogger("app.realtime")
SEND_TIMEOUT_S = 5.0


@dataclass
class _Client:
    ws: WebSocket
    expires_at: datetime | None


class LiveHub:
    def __init__(self) -> None:
        self._clients: dict[int, _Client] = {}
        self.latest_snapshot: dict[str, Any] | None = None

    @property
    def client_count(self) -> int:
        return len(self._clients)

    def register(self, ws: WebSocket, expires_at: datetime | None) -> None:
        self._clients[id(ws)] = _Client(ws, expires_at)

    def unregister(self, ws: WebSocket) -> None:
        self._clients.pop(id(ws), None)

    async def _send(self, client: _Client, message: dict[str, Any]) -> bool:
        if client.expires_at is not None and utcnow() >= client.expires_at:
            try:
                await client.ws.close(code=4401, reason="TOKEN_EXPIRED")
            except Exception:
                pass
            return False
        try:
            await asyncio.wait_for(client.ws.send_json(message), SEND_TIMEOUT_S)
            return True
        except Exception:
            return False

    async def broadcast(self, message: dict[str, Any]) -> None:
        clients = list(self._clients.values())
        if not clients:
            return
        results = await asyncio.gather(*(self._send(c, message) for c in clients))
        for client, ok in zip(clients, results):
            if not ok:
                self.unregister(client.ws)

    async def publish_snapshot(self, snapshot: dict[str, Any]) -> None:
        self.latest_snapshot = snapshot
        await self.broadcast(snapshot)

    def reset(self) -> None:
        self._clients.clear()
        self.latest_snapshot = None


hub = LiveHub()


def queue_event(db: AsyncSession, event_type: str, **data: Any) -> None:
    """Broadcast `event_type` once the current transaction commits."""
    payload = {"type": "event", "event": event_type, "at": utcnow().isoformat(), **data}
    db.info.setdefault("live_events", []).append(payload)


@event.listens_for(Session, "after_commit")
def _after_commit(session: Session) -> None:
    events = session.info.pop("live_events", None)
    if not events:
        return
    try:
        loop = asyncio.get_running_loop()
    except RuntimeError:
        return
    for payload in events:
        loop.create_task(hub.broadcast(payload))


@event.listens_for(Session, "after_rollback")
def _after_rollback(session: Session) -> None:
    session.info.pop("live_events", None)
