"""Tracking sessions (trips): start, stop, listing and idle timeout."""
import uuid
from datetime import datetime, timedelta

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import get_settings
from app.core.errors import AppError, not_found
from app.core.time import utcnow
from app.models.enums import (
    EmergencyEndReason,
    SessionEndReason,
    TelemetrySource,
    TrackingStatus,
    VehicleStatus,
)
from app.models.telemetry import TrackingSession, VehicleLiveState
from app.models.user import User
from app.repositories import audit_repo
from app.schemas.telemetry import TrackingSessionOut


def to_out(session: TrackingSession, now: datetime | None = None) -> TrackingSessionOut:
    now = now or utcnow()
    end = session.ended_at or now
    duration = max(0.0, (end - session.started_at).total_seconds())
    return TrackingSessionOut(
        id=session.id,
        vehicle_id=session.vehicle_id,
        started_at=session.started_at,
        ended_at=session.ended_at,
        end_reason=session.end_reason,
        packet_count=session.packet_count,
        rejected_count=session.rejected_count,
        distance_m=round(session.distance_m, 1),
        max_speed_mps=session.max_speed_mps,
        avg_speed_mps=round(session.distance_m / duration, 2) if duration >= 1 else None,
        duration_s=round(duration, 1),
        last_recorded_at=session.last_recorded_at,
    )


def tracking_status(
    session: TrackingSession | None, live: VehicleLiveState | None, now: datetime
) -> TrackingStatus:
    if session is None or session.ended_at is not None:
        return TrackingStatus.NOT_TRACKING
    fresh = live is not None and (now - live.recorded_at).total_seconds() <= get_settings().live_window_s
    return TrackingStatus.TRANSMITTING if fresh else TrackingStatus.STALE


async def open_session(db: AsyncSession, vehicle_id: uuid.UUID) -> TrackingSession | None:
    return await db.scalar(
        select(TrackingSession)
        .where(TrackingSession.vehicle_id == vehicle_id, TrackingSession.ended_at.is_(None))
        .order_by(TrackingSession.started_at.desc())
        .limit(1)
    )


async def close_session(
    db: AsyncSession, session: TrackingSession, reason: SessionEndReason, now: datetime,
    *, end_emergency: EmergencyEndReason | None = EmergencyEndReason.TRACKING_STOPPED, actor: User | None = None,
) -> None:
    """Close without committing. An active emergency cannot outlive its tracking session."""
    from app.services import emergency_service

    session.ended_at = now
    session.end_reason = reason
    if end_emergency is not None:
        await emergency_service.end_active_for_vehicle(db, session.vehicle_id, end_emergency, now, actor=actor)


async def start(
    db: AsyncSession, owner: User, vehicle_id: uuid.UUID, installation_id: str | None
) -> TrackingSession:
    from app.services import telemetry_service, vehicle_service

    vehicle = await vehicle_service.owned_vehicle(db, owner, vehicle_id)
    if vehicle.status != VehicleStatus.ACTIVE:
        raise AppError(409, "VEHICLE_NOT_ACTIVE", "This vehicle is not active.")
    device = await telemetry_service.active_device(db, vehicle.id, installation_id)

    now = utcnow()
    existing = await open_session(db, vehicle.id)
    if existing is not None:
        # Restarting keeps emergency mode only if it is re-activated deliberately.
        await close_session(db, existing, SessionEndReason.RESTARTED, now)
    session = TrackingSession(vehicle_id=vehicle.id, device_id=device.id, source=TelemetrySource.MOBILE, started_at=now)
    db.add(session)
    await db.flush()
    await audit_repo.record(
        db, "tracking.started", actor_user_id=owner.id, target_type="vehicle", target_id=vehicle.id,
        details={"sessionId": str(session.id)},
    )
    await db.commit()
    return session


async def stop(
    db: AsyncSession, owner: User, vehicle_id: uuid.UUID, session_id: uuid.UUID | None
) -> TrackingSession | None:
    from app.services import vehicle_service

    vehicle = await vehicle_service.owned_vehicle(db, owner, vehicle_id)
    session = await open_session(db, vehicle.id)
    if session is None:
        return None
    if session_id is not None and session.id != session_id:
        raise AppError(409, "SESSION_MISMATCH", "A different tracking session is active for this vehicle.")
    await close_session(db, session, SessionEndReason.USER, utcnow(), actor=owner)
    await audit_repo.record(
        db, "tracking.stopped", actor_user_id=owner.id, target_type="vehicle", target_id=vehicle.id,
        details={"sessionId": str(session.id)},
    )
    await db.commit()
    return session


async def list_sessions(db: AsyncSession, owner: User, vehicle_id: uuid.UUID, limit: int) -> list[TrackingSessionOut]:
    from app.services import vehicle_service

    vehicle = await vehicle_service.owned_vehicle(db, owner, vehicle_id)
    rows = await db.scalars(
        select(TrackingSession)
        .where(TrackingSession.vehicle_id == vehicle.id)
        .order_by(TrackingSession.started_at.desc())
        .limit(limit)
    )
    now = utcnow()
    return [to_out(s, now) for s in rows]


async def get_owned_session(db: AsyncSession, owner: User, vehicle_id: uuid.UUID, session_id: uuid.UUID) -> TrackingSession:
    from app.services import vehicle_service

    vehicle = await vehicle_service.owned_vehicle(db, owner, vehicle_id)
    session = await db.get(TrackingSession, session_id)
    if session is None or session.vehicle_id != vehicle.id:
        raise not_found("Tracking session")
    return session


async def close_idle(db: AsyncSession, now: datetime) -> int:
    """Close sessions whose phone went silent (app killed, battery died). Not committed."""
    cutoff = now - timedelta(seconds=get_settings().session_idle_timeout_s)
    rows = list(await db.scalars(select(TrackingSession).where(TrackingSession.ended_at.is_(None))))
    closed = 0
    for session in rows:
        last = session.last_recorded_at or session.started_at
        if last < cutoff and session.source == TelemetrySource.MOBILE:
            await close_session(db, session, SessionEndReason.TIMEOUT, now, end_emergency=EmergencyEndReason.TIMEOUT)
            closed += 1
    return closed


async def close_all_for_vehicle(
    db: AsyncSession, vehicle_id: uuid.UUID, reason: SessionEndReason, now: datetime,
    end_emergency: EmergencyEndReason | None,
) -> None:
    rows = list(
        await db.scalars(
            select(TrackingSession).where(TrackingSession.vehicle_id == vehicle_id, TrackingSession.ended_at.is_(None))
        )
    )
    for session in rows:
        await close_session(db, session, reason, now, end_emergency=end_emergency)
