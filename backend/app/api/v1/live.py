"""WebSocket for manager dashboards.

Protocol: connect, then send {"type": "auth", "accessToken": "..."} within 10 s. The token
never travels in the URL (URLs end up in logs). The server replies {"type": "hello"}, then
pushes {"type": "snapshot"} after every engine cycle and {"type": "event"} for emergencies.
Close codes: 4401 not authenticated / token expired, 4403 not a manager.
"""
import asyncio
import contextlib

from fastapi import APIRouter, Depends, WebSocket, WebSocketDisconnect
from sqlalchemy.ext.asyncio import async_sessionmaker

from app.core.errors import AppError
from app.core.security import decode_access_token
from app.core.time import utcnow
from app.db.session import get_session_factory
from app.models.enums import UserRole
from app.realtime.hub import hub
from app.repositories import user_repo

router = APIRouter(tags=["live"])
AUTH_TIMEOUT_S = 10.0


@router.websocket("/live/ws")
async def live(ws: WebSocket, factory: async_sessionmaker = Depends(get_session_factory)) -> None:
    await ws.accept()
    try:
        first = await asyncio.wait_for(ws.receive_json(), AUTH_TIMEOUT_S)
        token = first.get("accessToken") if isinstance(first, dict) and first.get("type") == "auth" else None
        if not isinstance(token, str):
            raise AppError(401, "NOT_AUTHENTICATED", "auth message required")
        claims = decode_access_token(token)
    except (asyncio.TimeoutError, AppError, ValueError, WebSocketDisconnect):
        with contextlib.suppress(Exception):
            await ws.close(code=4401, reason="NOT_AUTHENTICATED")
        return

    async with factory() as db:
        user = await user_repo.get_by_id(db, claims.user_id)
    if user is None or not user.is_active or user.role not in (UserRole.MANAGER, UserRole.ADMIN):
        await ws.close(code=4403, reason="FORBIDDEN")
        return

    hub.register(ws, claims.expires_at)
    try:
        await ws.send_json({"type": "hello", "serverTime": utcnow().isoformat(), "role": user.role.value})
        if hub.latest_snapshot is not None:
            await ws.send_json(hub.latest_snapshot)
        while True:
            message = await ws.receive_json()
            if isinstance(message, dict) and message.get("type") == "ping":
                await ws.send_json({"type": "pong", "serverTime": utcnow().isoformat()})
    except (WebSocketDisconnect, RuntimeError, ValueError):
        pass
    finally:
        hub.unregister(ws)
