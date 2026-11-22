"""Digital V2I: accounts, sessions with a join code, and the relay WebSocket.

Roles are never taken from the phone: the host of a session (ADMIN / MANAGER) is its
intersection, END_USER accounts that joined with the code are its vehicles, with the vehicle id
and emergency authorisation stored on the server.
"""
import asyncio
import contextlib
import json
import uuid

from fastapi import APIRouter, Depends, Query, Request, WebSocket, WebSocketDisconnect, status
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.api.deps import get_current_user, require_admin, require_end_user, require_manager
from app.core.errors import AppError
from app.core.rate_limit import limiter
from app.core.security import decode_access_token
from app.core.time import utcnow
from app.db.session import get_db, get_session_factory
from app.models.enums import V2IEmergencyStatus
from app.models.user import User
from app.realtime.v2i_relay import MAX_MESSAGE_BYTES, Peer, relay
from app.repositories import user_repo
from app.schemas.v2i import (
    EmergencyDecisionIn,
    EmergencyRequestIn,
    JoinedOut,
    JoinIn,
    ProfileOut,
    SessionCreateIn,
    SessionOut,
    SessionStateOut,
    V2IMeOut,
)
from app.services import v2i_service

router = APIRouter(prefix="/v2i", tags=["digital v2i"])
AUTH_TIMEOUT_S = 10.0


@router.get("/me", response_model=V2IMeOut)
async def me(user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)) -> V2IMeOut:
    return await v2i_service.me(db, user)


@router.post("/me/emergency-request", response_model=V2IMeOut)
@limiter.limit("5/hour")
async def request_emergency(
    request: Request, body: EmergencyRequestIn, user: User = Depends(require_end_user), db: AsyncSession = Depends(get_db)
) -> V2IMeOut:
    return await v2i_service.request_emergency(db, user, body.reason)


@router.get("/profiles", response_model=list[ProfileOut])
async def list_profiles(
    emergency_status: V2IEmergencyStatus | None = Query(default=None, alias="emergencyStatus"),
    limit: int = Query(default=100, ge=1, le=500),
    _: User = Depends(require_admin),
    db: AsyncSession = Depends(get_db),
) -> list[ProfileOut]:
    return await v2i_service.list_profiles(db, emergency_status, limit)


@router.put("/profiles/emergency", response_model=ProfileOut)
async def decide_emergency(
    body: EmergencyDecisionIn, admin: User = Depends(require_admin), db: AsyncSession = Depends(get_db)
) -> ProfileOut:
    return await v2i_service.decide_emergency(db, admin, body)


@router.post("/sessions", response_model=SessionOut, status_code=status.HTTP_201_CREATED)
async def create_session(
    body: SessionCreateIn, host: User = Depends(require_manager), db: AsyncSession = Depends(get_db)
) -> SessionOut:
    return await v2i_service.create_session(db, host, body)


@router.get("/sessions/mine", response_model=list[SessionOut])
async def my_sessions(
    include_closed: bool = Query(default=False, alias="includeClosed"),
    host: User = Depends(require_manager),
    db: AsyncSession = Depends(get_db),
) -> list[SessionOut]:
    return await v2i_service.my_sessions(db, host, include_closed)


@router.get("/sessions/{session_id}", response_model=SessionOut)
async def get_session(
    session_id: uuid.UUID, user: User = Depends(require_manager), db: AsyncSession = Depends(get_db)
) -> SessionOut:
    return await v2i_service.session_out(db, await v2i_service.host_session(db, user, session_id))


@router.post("/sessions/{session_id}/close", response_model=SessionOut)
async def close_session(
    session_id: uuid.UUID, user: User = Depends(require_manager), db: AsyncSession = Depends(get_db)
) -> SessionOut:
    return await v2i_service.close_session(db, user, session_id)


@router.get("/sessions/{session_id}/state", response_model=SessionStateOut)
async def session_state(
    session_id: uuid.UUID, user: User = Depends(require_manager), db: AsyncSession = Depends(get_db)
) -> SessionStateOut:
    return await v2i_service.session_state(db, user, session_id)


@router.post("/join", response_model=JoinedOut)
@limiter.limit("10/minute")
async def join(
    request: Request, body: JoinIn, user: User = Depends(require_end_user), db: AsyncSession = Depends(get_db)
) -> JoinedOut:
    return await v2i_service.join(db, user, body.join_code)


@router.get("/joined", response_model=list[JoinedOut])
async def joined(user: User = Depends(require_end_user), db: AsyncSession = Depends(get_db)) -> list[JoinedOut]:
    return await v2i_service.joined_sessions(db, user)


@router.websocket("/ws")
async def relay_ws(ws: WebSocket, factory: async_sessionmaker = Depends(get_session_factory)) -> None:
    """CloudRelayTransport. First message: {"type":"auth","accessToken":"...","sessionId":"..."}
    within 10 s (the token never goes in the URL). The server answers {"k":"hello","as":...}.
    Later {"k":"auth","accessToken":"..."} extends the connection with a refreshed token.
    Close codes: 4401 not authenticated / token expired, 4403 not host or member,
    4404 no open session, 4409 replaced by a newer connection, 4410 session closed."""
    await ws.accept()
    try:
        first = await asyncio.wait_for(ws.receive_json(), AUTH_TIMEOUT_S)
        if not isinstance(first, dict) or first.get("type") != "auth":
            raise AppError(401, "NOT_AUTHENTICATED", "auth message required")
        token, sid = first.get("accessToken"), first.get("sessionId")
        if not isinstance(token, str) or not isinstance(sid, str):
            raise AppError(401, "NOT_AUTHENTICATED", "auth message required")
        claims = decode_access_token(token)
        session_id = uuid.UUID(sid)
    except (asyncio.TimeoutError, AppError, ValueError, WebSocketDisconnect):
        with contextlib.suppress(Exception):
            await ws.close(code=4401, reason="NOT_AUTHENTICATED")
        return

    async with factory() as db:
        user = await user_repo.get_by_id(db, claims.user_id)
        if user is None or not user.is_active:
            await ws.close(code=4401, reason="NOT_AUTHENTICATED")
            return
        try:
            session, role, profile = await v2i_service.relay_role(db, user, session_id)
        except AppError as e:
            await ws.close(code=4404 if e.status_code == 404 else 4403, reason=e.code)
            return

    peer = Peer(ws=ws, user_id=user.id, role=role, expires_at=claims.expires_at,
                vid=profile.vehicle_id if profile else None, emergency=bool(profile and profile.emergency))
    # hello first, then the relay's own messages (member list, presence)
    await peer.send({
        "k": "hello", "as": role, "vid": peer.vid, "emergency": peer.emergency,
        "session": {"id": str(session.id), "name": session.name,
                    "centerLat": session.center_lat, "centerLon": session.center_lon},
        "intersectionOnline": role == "intersection" or relay.intersection_online(session.id),
        "serverTime": utcnow().isoformat(),
    })
    await relay.attach(session.id, peer)
    try:
        while not peer.closed:
            text = await ws.receive_text()
            if utcnow() >= peer.expires_at:
                await peer.close(4401, "TOKEN_EXPIRED")
                break
            if len(text) > MAX_MESSAGE_BYTES:
                await peer.close(1009, "TOO_BIG")
                break
            if text.startswith('{"k":"auth"'):
                _reauth(peer, text)
                continue
            await relay.handle(session.id, peer, text)
    except (WebSocketDisconnect, RuntimeError):
        pass
    finally:
        await relay.detach(session.id, peer)


def _reauth(peer: Peer, text: str) -> None:
    """A refreshed access token of the same account extends the connection."""
    with contextlib.suppress(ValueError, AppError, TypeError):
        token = json.loads(text).get("accessToken")
        claims = decode_access_token(token)
        if claims.user_id == peer.user_id:
            peer.expires_at = claims.expires_at
