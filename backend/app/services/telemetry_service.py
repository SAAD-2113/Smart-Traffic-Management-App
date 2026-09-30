"""Telemetry ingestion. The server never trusts the client: every packet is re-validated.

Per packet, in order: value ranges → timestamp window → ordering within the session
(replay protection) → minimum interval → movement plausibility. Accepted packets become
history rows; packets that are still fresh ("live") also update the vehicle's live state.
The emergency flag stored is the server's own decision, never the packet's.
"""
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Protocol

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from traffic_engine import Network, Observation, Source, map_observation
from traffic_engine.geo import haversine_m

from app.core.config import Settings, get_settings
from app.core.errors import AppError
from app.core.time import utcnow
from app.models.enums import (
    DeviceStatus,
    GpsQuality,
    SpeedSource,
    TelemetrySource,
    TrafficZone,
    VehicleStatus,
)
from app.models.telemetry import TrackingSession, VehicleLiveState, VehicleTelemetry
from app.models.user import User
from app.models.vehicle import Device, Vehicle
from app.schemas.telemetry import PacketResult, TelemetryBatch, TelemetryBatchResult
from app.services import network_cache
from app.services.network_cache import NetworkRefs

JUMP_CHECK_MAX_GAP_S = 30.0   # beyond this gap a jump cannot be judged (tunnel, GPS restart)
JUMP_RESET_STREAK = 3          # consistent "jumps" mean the previous anchor was wrong: re-anchor
SESSION_START_TOLERANCE_S = 60.0


class PacketLike(Protocol):
    seq: int
    recorded_at: datetime
    lat: float
    lon: float
    accuracy_m: float
    speed_mps: float | None
    speed_source: SpeedSource | None
    heading_deg: float | None
    altitude_m: float | None
    mocked: bool


def check_ranges(p, s: Settings) -> str | None:
    if not (-90.0 <= p.lat <= 90.0 and -180.0 <= p.lon <= 180.0) or (p.lat == 0.0 and p.lon == 0.0):
        return "INVALID_COORDINATES"
    if p.accuracy_m <= 0:
        return "INVALID_ACCURACY"
    if p.accuracy_m > s.max_accuracy_m:
        return "LOW_ACCURACY"
    if p.speed_mps is not None:
        if p.speed_mps < 0:
            return "INVALID_SPEED"
        if p.speed_mps > s.max_speed_mps:
            return "UNREALISTIC_SPEED"
    if getattr(p, "speed_accuracy_mps", None) is not None and p.speed_accuracy_mps < 0:
        return "INVALID_SPEED"
    if p.heading_deg is not None and not 0.0 <= p.heading_deg < 360.0:
        return "INVALID_HEADING"
    if p.altitude_m is not None and not -500.0 <= p.altitude_m <= 9000.0:
        return "INVALID_ALTITUDE"
    return None


def check_time(recorded_at: datetime, now: datetime, s: Settings) -> str | None:
    age = (now - recorded_at).total_seconds()
    if age < -s.future_tolerance_s:
        return "FUTURE_TIMESTAMP"
    if age > s.backfill_max_age_s:
        return "STALE_TIMESTAMP"
    return None


def check_sequence(p, session: TrackingSession, s: Settings) -> str | None:
    if p.recorded_at < session.started_at - timedelta(seconds=SESSION_START_TOLERANCE_S):
        return "DUPLICATE_OR_OUT_OF_ORDER"
    if session.last_seq is not None and p.seq <= session.last_seq:
        return "DUPLICATE_OR_OUT_OF_ORDER"
    if session.last_recorded_at is None:
        return None
    dt = (p.recorded_at - session.last_recorded_at).total_seconds()
    if dt <= 0:
        return "DUPLICATE_OR_OUT_OF_ORDER"
    if dt < s.min_packet_interval_s:
        return "TOO_FREQUENT"
    if dt <= JUMP_CHECK_MAX_GAP_S and session.last_lat is not None:
        distance = haversine_m(session.last_lat, session.last_lon, p.lat, p.lon)
        slack = (session.last_accuracy_m or 0.0) + p.accuracy_m
        if max(0.0, distance - slack) / dt > s.max_jump_speed_mps:
            return "IMPLAUSIBLE_JUMP"
    return None


@dataclass
class IngestOutcome:
    results: list[PacketResult]
    accepted: int
    rejected: int
    latest_live: VehicleLiveState | None


def _map(
    network: Network, refs: NetworkRefs, vehicle: Vehicle, p, source: TelemetrySource, emergency: bool
) -> tuple[uuid.UUID | None, uuid.UUID | None, TrafficZone | None]:
    obs = Observation(
        key=f"veh:{vehicle.id}", source=Source(source.value), lat=p.lat, lon=p.lon, recorded_at=p.recorded_at,
        accuracy_m=p.accuracy_m, speed_mps=p.speed_mps, heading_deg=p.heading_deg, emergency=emergency,
        vehicle_type=vehicle.vehicle_type.value, label=vehicle.code,
    )
    m = map_observation(obs, network)
    code = m.intersection_code or m.link_to_code
    approach = m.approach_name if m.intersection_code else m.link_to_approach
    info = refs.by_code.get(code) if code else None
    return (
        info.id if info else None,
        refs.approach_ids.get((code, approach)) if code and approach else None,
        TrafficZone(m.zone.value) if m.zone else None,
    )


async def ingest(
    db: AsyncSession,
    *,
    vehicle: Vehicle,
    session: TrackingSession,
    packets: list,
    source: TelemetrySource,
    emergency_active: bool,
    now: datetime,
    network: Network,
    refs: NetworkRefs,
    settings: Settings | None = None,
) -> IngestOutcome:
    s = settings or get_settings()
    results: list[PacketResult] = []
    rows: list[VehicleTelemetry] = []
    latest: tuple = ()
    for p in packets:
        reason = check_ranges(p, s) or check_time(p.recorded_at, now, s) or check_sequence(p, session, s)
        reanchored = False
        if reason == "IMPLAUSIBLE_JUMP":
            session.jump_streak += 1
            if session.jump_streak >= JUMP_RESET_STREAK:
                reason, reanchored = None, True
        if reason is not None:
            session.rejected_count += 1
            results.append(PacketResult(seq=p.seq, status="REJECTED", reason=reason))
            continue

        session.jump_streak = 0
        live = (now - p.recorded_at).total_seconds() <= s.live_window_s
        usable = p.accuracy_m <= s.usable_accuracy_m and not p.mocked
        emergency = live and emergency_active
        intersection_id = approach_id = zone = None
        if live and usable:
            intersection_id, approach_id, zone = _map(network, refs, vehicle, p, source, emergency)

        speed_source = p.speed_source or (SpeedSource.GPS if p.speed_mps is not None else None)
        rows.append(
            VehicleTelemetry(
                vehicle_id=vehicle.id, session_id=session.id, source=source, seq=p.seq,
                recorded_at=p.recorded_at, received_at=now, lat=p.lat, lon=p.lon, accuracy_m=p.accuracy_m,
                speed_mps=p.speed_mps, speed_source=speed_source, heading_deg=p.heading_deg,
                altitude_m=p.altitude_m, emergency=emergency, is_mock=p.mocked, is_live=live, usable=usable,
                intersection_id=intersection_id, approach_id=approach_id, zone=zone,
            )
        )

        # Session statistics and the cursor used for ordering and plausibility checks.
        if (
            usable and not reanchored and session.last_lat is not None
            and (session.last_accuracy_m or 999) <= s.usable_accuracy_m
        ):
            session.distance_m += haversine_m(session.last_lat, session.last_lon, p.lat, p.lon)
        if p.speed_mps is not None:
            session.max_speed_mps = max(session.max_speed_mps or 0.0, p.speed_mps)
        session.packet_count += 1
        session.last_seq = p.seq
        session.last_recorded_at = p.recorded_at
        session.last_lat, session.last_lon, session.last_accuracy_m = p.lat, p.lon, p.accuracy_m
        results.append(PacketResult(seq=p.seq, status="ACCEPTED", live=live, usable=usable))
        if live:
            latest = (p, usable, emergency, intersection_id, approach_id, zone, reanchored)

    db.add_all(rows)
    live_state = None
    if latest:
        live_state = await _upsert_live_state(db, vehicle, session, source, now, *latest)
    accepted = sum(1 for r in results if r.status == "ACCEPTED")
    return IngestOutcome(results=results, accepted=accepted, rejected=len(results) - accepted, latest_live=live_state)


async def _upsert_live_state(
    db: AsyncSession, vehicle: Vehicle, session: TrackingSession, source: TelemetrySource, now: datetime,
    p, usable: bool, emergency: bool, intersection_id, approach_id, zone, reanchored: bool,
) -> VehicleLiveState:
    state = await db.get(VehicleLiveState, vehicle.id)
    if state is None:
        state = VehicleLiveState(vehicle_id=vehicle.id)
        db.add(state)
    elif state.recorded_at >= p.recorded_at and state.session_id == session.id:
        return state
    state.session_id = session.id
    state.source = source
    state.recorded_at = p.recorded_at
    state.received_at = now
    state.lat, state.lon, state.accuracy_m = p.lat, p.lon, p.accuracy_m
    state.gps_quality = GpsQuality.from_accuracy(p.accuracy_m)
    state.speed_mps = p.speed_mps
    state.heading_deg = p.heading_deg
    state.emergency = emergency
    state.usable = usable
    state.intersection_id, state.approach_id, state.zone = intersection_id, approach_id, zone
    state.note = "mock location" if p.mocked else ("position re-anchored" if reanchored else None)
    return state


async def active_device(db: AsyncSession, vehicle_id: uuid.UUID, installation_id: str | None) -> Device:
    if not installation_id:
        raise AppError(400, "INSTALLATION_ID_REQUIRED", "X-Installation-Id header is required.")
    device = await db.scalar(
        select(Device).where(
            Device.vehicle_id == vehicle_id,
            Device.installation_id == installation_id,
            Device.status == DeviceStatus.ACTIVE,
        )
    )
    if device is None:
        raise AppError(409, "DEVICE_NOT_BOUND", "This phone is not the active device of the vehicle.")
    return device


async def ingest_mobile(
    db: AsyncSession, owner: User, vehicle_id: uuid.UUID, installation_id: str | None, batch: TelemetryBatch
) -> TelemetryBatchResult:
    from app.services import emergency_service, vehicle_service  # avoid import cycles

    s = get_settings()
    now = utcnow()
    if len(batch.packets) > s.telemetry_batch_max:
        raise AppError(422, "BATCH_TOO_LARGE", f"Send at most {s.telemetry_batch_max} packets per request.")
    vehicle = await vehicle_service.owned_vehicle(db, owner, vehicle_id)
    if vehicle.status != VehicleStatus.ACTIVE:
        raise AppError(409, "VEHICLE_NOT_ACTIVE", "This vehicle is not active.")
    device = await active_device(db, vehicle.id, installation_id)
    session = await db.get(TrackingSession, batch.session_id)
    if session is None or session.vehicle_id != vehicle.id or session.ended_at is not None:
        raise AppError(409, "SESSION_NOT_ACTIVE", "This tracking session is not active. Start tracking again.")

    emergency_active = await emergency_service.has_valid_active_event(db, vehicle, now)
    network, refs = await network_cache.load(db)
    outcome = await ingest(
        db, vehicle=vehicle, session=session, packets=batch.packets, source=TelemetrySource.MOBILE,
        emergency_active=emergency_active, now=now, network=network, refs=refs, settings=s,
    )
    device.last_seen_at = now
    await db.commit()
    return TelemetryBatchResult(
        accepted=outcome.accepted, rejected=outcome.rejected, results=outcome.results,
        emergency_active=emergency_active, server_time=now,
    )
