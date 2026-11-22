"""Digital V2I relay (CloudRelayTransport, server side).

One room per session: the host's intersection phone and the vehicle phones. Vehicles send
"pos" packets, the intersection answers each with an ACK, which goes back to that vehicle only.
The intersection also posts its state JSON every 500 ms; the server keeps the latest copy for
the session's host and managers. Vehicles never receive other vehicles' data.

Messages are JSON objects with a "k" field; packet texts travel unchanged in "raw".
  vehicle -> server        {"k":"pos","raw":"{\"t\":\"pos\",...}"}   {"k":"rtt","ms":87}   {"k":"ping"}
  server  -> intersection  {"k":"pos","vid":1001,"raw":...}  {"k":"rtt","vid":1001,"ms":87}
                           {"k":"member","vid":1001,"online":true,"emergency":false}
  intersection -> server   {"k":"ack","to":1001,"raw":"{\"t\":\"ack\",...}"}  {"k":"state","raw":...}
  server  -> vehicle       {"k":"ack","raw":...}  {"k":"intersection","online":true}
                           {"k":"profile","emergency":true}
  errors                   {"k":"err","code":"...","message":"..."}

The relay keeps everything in memory (one server process). It does not run any signal logic.
"""
import asyncio
import contextlib
import json
import time
import uuid
from dataclasses import dataclass, field
from datetime import datetime
from typing import Any

from fastapi import WebSocket

from app.core.time import utcnow
from app.services import v2i_packets
from app.services.v2i_packets import PacketError

CLOSE_REPLACED = 4409
CLOSE_SESSION_CLOSED = 4410
MAX_MESSAGE_BYTES = 64 * 1024


class TokenBucket:
    def __init__(self, rate_per_s: float, burst: float) -> None:
        self.rate, self.burst = rate_per_s, burst
        self.tokens, self.at = burst, time.monotonic()

    def take(self) -> bool:
        now = time.monotonic()
        self.tokens = min(self.burst, self.tokens + (now - self.at) * self.rate)
        self.at = now
        if self.tokens < 1:
            return False
        self.tokens -= 1
        return True


@dataclass(eq=False)
class Peer:
    ws: WebSocket
    user_id: uuid.UUID
    role: str  # "intersection" | "vehicle" (decided by the server)
    expires_at: datetime
    vid: int | None = None
    emergency: bool = False
    bucket: TokenBucket = field(default_factory=lambda: TokenBucket(4.0, 10.0))
    lock: asyncio.Lock = field(default_factory=asyncio.Lock)
    last_error_at: dict[str, float] = field(default_factory=dict)
    closed: bool = False

    async def send(self, message: dict[str, Any]) -> None:
        if self.closed:
            return
        try:
            async with self.lock:
                await self.ws.send_text(json.dumps(message, separators=(",", ":")))
        except Exception:  # noqa: BLE001 - a dead socket is cleaned up by its own handler
            self.closed = True

    async def close(self, code: int, reason: str) -> None:
        self.closed = True
        with contextlib.suppress(Exception):
            await self.ws.close(code=code, reason=reason)

    async def error(self, code: str, message: str, throttle_s: float = 0.0) -> None:
        """Sends an error; [throttle_s] limits how often the same code is repeated."""
        now = time.monotonic()
        if throttle_s and now - self.last_error_at.get(code, -1e9) < throttle_s:
            return
        self.last_error_at[code] = now
        await self.send({"k": "err", "code": code, "message": message})


@dataclass(eq=False)
class Room:
    session_id: uuid.UUID
    intersection: Peer | None = None
    vehicles: dict[int, Peer] = field(default_factory=dict)
    state: dict[str, Any] | None = None
    state_at: datetime | None = None
    forwarded: int = 0
    rejected: int = 0


class V2IRelay:
    def __init__(self) -> None:
        self.rooms: dict[uuid.UUID, Room] = {}

    def reset(self) -> None:
        self.rooms = {}

    def room(self, session_id: uuid.UUID) -> Room:
        return self.rooms.setdefault(session_id, Room(session_id))

    def intersection_online(self, session_id: uuid.UUID) -> bool:
        r = self.rooms.get(session_id)
        return bool(r and r.intersection and not r.intersection.closed)

    def online_vehicles(self, session_id: uuid.UUID) -> int:
        r = self.rooms.get(session_id)
        return len(r.vehicles) if r else 0

    async def attach(self, session_id: uuid.UUID, peer: Peer) -> None:
        room = self.room(session_id)
        if peer.role == "intersection":
            old, room.intersection = room.intersection, peer
            if old is not None:
                await old.close(CLOSE_REPLACED, "REPLACED")
            for v in room.vehicles.values():
                await v.send({"k": "intersection", "online": True})
            await peer.send({"k": "members", "vehicles": [
                {"vid": v.vid, "emergency": v.emergency} for v in room.vehicles.values()]})
        else:
            assert peer.vid is not None
            old = room.vehicles.get(peer.vid)
            room.vehicles[peer.vid] = peer
            if old is not None:
                await old.close(CLOSE_REPLACED, "REPLACED")
            if room.intersection:
                await room.intersection.send({"k": "member", "vid": peer.vid, "online": True, "emergency": peer.emergency})

    async def detach(self, session_id: uuid.UUID, peer: Peer) -> None:
        peer.closed = True
        room = self.rooms.get(session_id)
        if room is None:
            return
        if peer.role == "intersection":
            if room.intersection is peer:
                room.intersection = None
                for v in room.vehicles.values():
                    await v.send({"k": "intersection", "online": False})
        elif peer.vid is not None and room.vehicles.get(peer.vid) is peer:
            del room.vehicles[peer.vid]
            if room.intersection:
                await room.intersection.send({"k": "member", "vid": peer.vid, "online": False, "emergency": peer.emergency})

    async def close_session(self, session_id: uuid.UUID) -> None:
        room = self.rooms.pop(session_id, None)
        if room is None:
            return
        peers = [*room.vehicles.values()] + ([room.intersection] if room.intersection else [])
        for p in peers:
            await p.close(CLOSE_SESSION_CLOSED, "SESSION_CLOSED")

    async def set_emergency(self, user_id: uuid.UUID, allowed: bool) -> None:
        """An admin changed the account's authorisation: applies to its open connections at once."""
        for room in self.rooms.values():
            for v in room.vehicles.values():
                if v.user_id == user_id and v.emergency != allowed:
                    v.emergency = allowed
                    await v.send({"k": "profile", "emergency": allowed})
                    if room.intersection:
                        await room.intersection.send({"k": "member", "vid": v.vid, "online": True, "emergency": allowed})

    async def handle(self, session_id: uuid.UUID, peer: Peer, text: str) -> None:
        room = self.rooms.get(session_id)
        if room is None:
            return
        try:
            msg = json.loads(text)
        except ValueError:
            msg = None
        if not isinstance(msg, dict) or not isinstance(msg.get("k"), str):
            await peer.error("BAD_MESSAGE", 'messages are JSON objects with a "k" field', throttle_s=1)
            return
        kind = msg["k"]
        if kind == "ping":
            await peer.send({"k": "pong", "serverTime": utcnow().isoformat()})
            return
        if peer.role == "vehicle":
            await self._from_vehicle(room, peer, kind, msg)
        else:
            await self._from_intersection(room, peer, kind, msg)

    async def _from_vehicle(self, room: Room, peer: Peer, kind: str, msg: dict) -> None:
        if kind == "pos":
            if not peer.bucket.take():
                room.rejected += 1
                await peer.error("RATE_LIMITED", "at most 4 packets per second", throttle_s=1)
                return
            try:
                v2i_packets.validate_pos(msg.get("raw"), peer.vid or 0, peer.emergency)
            except PacketError as e:
                room.rejected += 1
                await peer.error(e.code, str(e))  # bounded by the rate limit above
                return
            if room.intersection is None:
                await peer.error("INTERSECTION_OFFLINE", "the intersection is not connected", throttle_s=2)
                return
            room.forwarded += 1
            await room.intersection.send({"k": "pos", "vid": peer.vid, "raw": msg["raw"]})
        elif kind == "rtt":
            ms = msg.get("ms")
            if isinstance(ms, int) and not isinstance(ms, bool) and 0 <= ms <= 60000 and room.intersection:
                await room.intersection.send({"k": "rtt", "vid": peer.vid, "ms": ms})
        else:
            await peer.error("BAD_MESSAGE", f"a vehicle cannot send {kind!r}", throttle_s=1)

    async def _from_intersection(self, room: Room, peer: Peer, kind: str, msg: dict) -> None:
        if kind == "ack":
            to = msg.get("to")
            try:
                v2i_packets.validate_ack(msg.get("raw"), to)
            except PacketError as e:
                await peer.error(e.code, str(e))
                return
            target = room.vehicles.get(to)
            if target is not None:
                await target.send({"k": "ack", "raw": msg["raw"]})
        elif kind == "state":
            try:
                room.state = v2i_packets.validate_state(msg.get("raw"))
            except PacketError as e:
                await peer.error(e.code, str(e), throttle_s=2)
                return
            room.state_at = utcnow()
        else:
            await peer.error("BAD_MESSAGE", f"the intersection cannot send {kind!r}", throttle_s=1)


relay = V2IRelay()
