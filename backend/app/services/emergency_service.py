"""Emergency vehicles: authorisation review and emergency events.

Emergency capability is a per-vehicle authorisation approved by a manager, never a role.
It is checked when an event starts and again on every telemetry packet.
"""
import uuid
from datetime import datetime, timedelta

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession
from traffic_engine import Observation, Source, map_observation

from app.core.config import get_settings
from app.core.errors import AppError, not_found
from app.core.time import utcnow
from app.models.emergency import EmergencyEvent
from app.models.enums import AuthorizationStatus, EmergencyEndReason, EmergencyEventStatus, VehicleStatus
from app.models.telemetry import VehicleLiveState
from app.models.user import User
from app.models.vehicle import EmergencyAuthorization, Vehicle
from app.realtime.hub import queue_event
from app.repositories import audit_repo, vehicle_repo
from app.schemas.emergency import (
    ActiveEmergencyOut,
    AuthorizationReviewOut,
    EmergencyEventOut,
    EmergencyStatusOut,
)
from app.services import network_cache
from app.services.vehicle_service import is_emergency_authorized


def event_out(event: EmergencyEvent, vehicle: Vehicle, now: datetime | None = None) -> EmergencyEventOut:
    now = now or utcnow()
    end = event.ended_at or now
    return EmergencyEventOut(
        id=event.id, vehicle_id=vehicle.id, vehicle_code=vehicle.code, vehicle_type=vehicle.vehicle_type,
        is_simulated=vehicle.is_simulated, status=event.status, started_at=event.started_at,
        ended_at=event.ended_at, end_reason=event.end_reason,
        duration_s=round(max(0.0, (end - event.started_at).total_seconds()), 1),
    )


async def latest_authorization(db: AsyncSession, vehicle_id: uuid.UUID) -> EmergencyAuthorization | None:
    return (await vehicle_repo.latest_authorizations(db, [vehicle_id])).get(vehicle_id)


async def active_event(db: AsyncSession, vehicle_id: uuid.UUID) -> EmergencyEvent | None:
    return await db.scalar(
        select(EmergencyEvent).where(
            EmergencyEvent.vehicle_id == vehicle_id, EmergencyEvent.status == EmergencyEventStatus.ACTIVE
        )
    )


async def has_valid_active_event(db: AsyncSession, vehicle: Vehicle, now: datetime) -> bool:
    if await active_event(db, vehicle.id) is None:
        return False
    return is_emergency_authorized(vehicle, await latest_authorization(db, vehicle.id), now)


def _event_payload(event: EmergencyEvent, vehicle: Vehicle) -> dict:
    return {
        "eventId": str(event.id), "vehicleId": str(vehicle.id), "vehicleCode": vehicle.code,
        "vehicleType": vehicle.vehicle_type.value, "isSimulated": vehicle.is_simulated,
    }


# -- driver side -----------------------------------------------------------------------

async def status_for_owner(db: AsyncSession, owner: User, vehicle_id: uuid.UUID) -> EmergencyStatusOut:
    from app.services import vehicle_service

    vehicle = await vehicle_service.owned_vehicle(db, owner, vehicle_id)
    now = utcnow()
    auth = await latest_authorization(db, vehicle.id)
    event = await active_event(db, vehicle.id)
    return EmergencyStatusOut(
        vehicle_id=vehicle.id,
        vehicle_type=vehicle.vehicle_type,
        eligible_type=vehicle.vehicle_type.is_emergency,
        authorization_status=auth.status if auth else None,
        authorized=is_emergency_authorized(vehicle, auth, now),
        authorization_valid_until=auth.valid_until if auth else None,
        active_event=event_out(event, vehicle, now) if event else None,
    )


async def _begin(
    db: AsyncSession, vehicle: Vehicle, session_id: uuid.UUID | None, actor_id: uuid.UUID | None, now: datetime
) -> EmergencyEvent:
    event = EmergencyEvent(
        vehicle_id=vehicle.id, session_id=session_id, status=EmergencyEventStatus.ACTIVE,
        started_at=now, started_by=actor_id,
    )
    db.add(event)
    await db.flush()
    await audit_repo.record(
        db, "emergency.started", actor_user_id=actor_id, target_type="vehicle", target_id=vehicle.id,
        details={"eventId": str(event.id), "simulated": vehicle.is_simulated},
    )
    queue_event(db, "EMERGENCY_STARTED", **_event_payload(event, vehicle))
    return event


async def start(
    db: AsyncSession, owner: User, vehicle_id: uuid.UUID, installation_id: str | None, confirm: bool
) -> EmergencyEventOut:
    from app.services import telemetry_service, tracking_service, vehicle_service

    if not confirm:
        raise AppError(422, "CONFIRMATION_REQUIRED", "Emergency mode must be confirmed explicitly.")
    vehicle = await vehicle_service.owned_vehicle(db, owner, vehicle_id)
    now = utcnow()
    if not vehicle.vehicle_type.is_emergency:
        raise AppError(403, "NOT_EMERGENCY_VEHICLE", "Only ambulance, fire and police vehicles can use emergency mode.")
    if not is_emergency_authorized(vehicle, await latest_authorization(db, vehicle.id), now):
        raise AppError(403, "EMERGENCY_NOT_AUTHORIZED", "This vehicle is not authorised for emergency mode.")
    await telemetry_service.active_device(db, vehicle.id, installation_id)

    existing = await active_event(db, vehicle.id)
    if existing is not None:
        return event_out(existing, vehicle, now)  # idempotent

    session = await tracking_service.open_session(db, vehicle.id)
    if session is None:
        raise AppError(409, "TRACKING_NOT_ACTIVE", "Start tracking before activating emergency mode.")
    live = await db.get(VehicleLiveState, vehicle.id)
    max_age = get_settings().emergency_start_max_fix_age_s
    if live is None or (now - live.recorded_at).total_seconds() > max_age:
        raise AppError(409, "NO_RECENT_LOCATION", "Waiting for a GPS fix. Emergency mode needs a current location.")

    event = await _begin(db, vehicle, session.id, owner.id, now)
    await db.commit()
    return event_out(event, vehicle, now)


async def start_simulated(db: AsyncSession, vehicle: Vehicle, session_id: uuid.UUID | None, now: datetime) -> None:
    """Demo fleet only. Still requires an approved authorisation. Not committed."""
    if not vehicle.is_simulated or await active_event(db, vehicle.id) is not None:
        return
    if not is_emergency_authorized(vehicle, await latest_authorization(db, vehicle.id), now):
        return
    await _begin(db, vehicle, session_id, None, now)


async def end_active_for_vehicle(
    db: AsyncSession, vehicle_id: uuid.UUID, reason: EmergencyEndReason, now: datetime,
    *, actor: User | None = None, note: str | None = None,
) -> EmergencyEvent | None:
    """End the vehicle's active event, if any. Not committed."""
    event = await active_event(db, vehicle_id)
    if event is None:
        return None
    event.status = EmergencyEventStatus.ENDED
    event.ended_at = now
    event.end_reason = reason
    event.ended_by = actor.id if actor else None
    event.note = note
    live = await db.get(VehicleLiveState, vehicle_id)
    if live is not None:
        live.emergency = False
    vehicle = await db.get(Vehicle, vehicle_id)
    await audit_repo.record(
        db, "emergency.ended", actor_user_id=actor.id if actor else None, target_type="vehicle",
        target_id=vehicle_id, details={"eventId": str(event.id), "reason": reason.value},
    )
    if vehicle is not None:
        queue_event(db, "EMERGENCY_ENDED", reason=reason.value, **_event_payload(event, vehicle))
    return event


async def stop(db: AsyncSession, owner: User, vehicle_id: uuid.UUID) -> EmergencyEventOut | None:
    from app.services import vehicle_service

    vehicle = await vehicle_service.owned_vehicle(db, owner, vehicle_id)
    now = utcnow()
    event = await end_active_for_vehicle(db, vehicle.id, EmergencyEndReason.DRIVER, now, actor=owner)
    await db.commit()
    return event_out(event, vehicle, now) if event else None


async def request_authorization(db: AsyncSession, owner: User, vehicle_id: uuid.UUID) -> EmergencyStatusOut:
    from app.services import vehicle_service

    vehicle = await vehicle_service.owned_vehicle(db, owner, vehicle_id)
    if not vehicle.vehicle_type.is_emergency:
        raise AppError(403, "NOT_EMERGENCY_VEHICLE", "Only ambulance, fire and police vehicles can request authorisation.")
    now = utcnow()
    auth = await latest_authorization(db, vehicle.id)
    if auth is not None and auth.status == AuthorizationStatus.PENDING:
        raise AppError(409, "AUTHORIZATION_PENDING", "A request is already waiting for review.")
    if is_emergency_authorized(vehicle, auth, now):
        raise AppError(409, "ALREADY_AUTHORIZED", "This vehicle is already authorised.")
    db.add(EmergencyAuthorization(vehicle_id=vehicle.id, status=AuthorizationStatus.PENDING, requested_by=owner.id,
                                  created_at=now))
    await audit_repo.record(db, "emergency.authorization_requested", actor_user_id=owner.id,
                            target_type="vehicle", target_id=vehicle.id)
    queue_event(db, "AUTHORIZATION_REQUESTED", vehicleCode=vehicle.code, vehicleType=vehicle.vehicle_type.value)
    await db.commit()
    return await status_for_owner(db, owner, vehicle.id)


# -- manager side ----------------------------------------------------------------------

def _review_out(auth: EmergencyAuthorization, vehicle: Vehicle) -> AuthorizationReviewOut:
    return AuthorizationReviewOut(
        id=auth.id, vehicle_id=vehicle.id, vehicle_code=vehicle.code, vehicle_type=vehicle.vehicle_type,
        registration_number=vehicle.registration_number, status=auth.status, requested_at=auth.created_at,
        reviewed_at=auth.reviewed_at, valid_until=auth.valid_until, notes=auth.notes,
    )


async def list_authorizations(
    db: AsyncSession, status: AuthorizationStatus | None, include_simulated: bool = False
) -> list[AuthorizationReviewOut]:
    stmt = (
        select(EmergencyAuthorization, Vehicle)
        .join(Vehicle, Vehicle.id == EmergencyAuthorization.vehicle_id)
        .order_by(EmergencyAuthorization.created_at.desc())
        .limit(200)
    )
    if status is not None:
        stmt = stmt.where(EmergencyAuthorization.status == status)
    if not include_simulated:
        stmt = stmt.where(Vehicle.is_simulated.is_(False))
    return [_review_out(a, v) for a, v in (await db.execute(stmt)).all()]


async def count_pending(db: AsyncSession) -> int:
    return await db.scalar(
        select(func.count()).select_from(EmergencyAuthorization)
        .join(Vehicle, Vehicle.id == EmergencyAuthorization.vehicle_id)
        .where(EmergencyAuthorization.status == AuthorizationStatus.PENDING, Vehicle.is_simulated.is_(False))
    ) or 0


async def _get_authorization(db: AsyncSession, auth_id: uuid.UUID) -> tuple[EmergencyAuthorization, Vehicle]:
    auth = await db.get(EmergencyAuthorization, auth_id)
    if auth is None:
        raise not_found("Authorisation request")
    vehicle = await db.get(Vehicle, auth.vehicle_id)
    return auth, vehicle


async def approve(
    db: AsyncSession, manager: User, auth_id: uuid.UUID, valid_until: datetime | None, notes: str | None
) -> AuthorizationReviewOut:
    auth, vehicle = await _get_authorization(db, auth_id)
    now = utcnow()
    if auth.status != AuthorizationStatus.PENDING:
        raise AppError(409, "NOT_PENDING", "Only pending requests can be approved.")
    if valid_until is not None and valid_until <= now:
        raise AppError(422, "INVALID_VALID_UNTIL", "validUntil must be in the future.")
    if vehicle.status != VehicleStatus.ACTIVE:
        raise AppError(409, "VEHICLE_NOT_ACTIVE", "This vehicle is not active.")
    auth.status, auth.reviewed_by, auth.reviewed_at = AuthorizationStatus.APPROVED, manager.id, now
    auth.valid_until, auth.notes = valid_until, notes
    await audit_repo.record(db, "emergency.authorization_approved", actor_user_id=manager.id,
                            target_type="vehicle", target_id=vehicle.id, details={"authorizationId": str(auth.id)})
    await db.commit()
    return _review_out(auth, vehicle)


async def reject(db: AsyncSession, manager: User, auth_id: uuid.UUID, notes: str) -> AuthorizationReviewOut:
    auth, vehicle = await _get_authorization(db, auth_id)
    if auth.status != AuthorizationStatus.PENDING:
        raise AppError(409, "NOT_PENDING", "Only pending requests can be rejected.")
    auth.status, auth.reviewed_by, auth.reviewed_at, auth.notes = AuthorizationStatus.REJECTED, manager.id, utcnow(), notes
    await audit_repo.record(db, "emergency.authorization_rejected", actor_user_id=manager.id,
                            target_type="vehicle", target_id=vehicle.id, details={"authorizationId": str(auth.id)})
    await db.commit()
    return _review_out(auth, vehicle)


async def revoke(db: AsyncSession, manager: User, vehicle_id: uuid.UUID, notes: str) -> AuthorizationReviewOut:
    vehicle = await db.get(Vehicle, vehicle_id)
    if vehicle is None:
        raise not_found("Vehicle")
    auth = await latest_authorization(db, vehicle.id)
    if auth is None or auth.status != AuthorizationStatus.APPROVED:
        raise AppError(409, "NOT_APPROVED", "This vehicle has no approved authorisation to revoke.")
    now = utcnow()
    auth.status, auth.reviewed_by, auth.reviewed_at, auth.notes = AuthorizationStatus.REVOKED, manager.id, now, notes
    await end_active_for_vehicle(db, vehicle.id, EmergencyEndReason.AUTH_REVOKED, now, actor=manager, note=notes)
    await audit_repo.record(db, "emergency.authorization_revoked", actor_user_id=manager.id,
                            target_type="vehicle", target_id=vehicle.id, details={"notes": notes})
    await db.commit()
    return _review_out(auth, vehicle)


async def manager_end(db: AsyncSession, manager: User, event_id: uuid.UUID, note: str) -> EmergencyEventOut:
    event = await db.get(EmergencyEvent, event_id)
    if event is None:
        raise not_found("Emergency event")
    vehicle = await db.get(Vehicle, event.vehicle_id)
    now = utcnow()
    if event.status == EmergencyEventStatus.ACTIVE:
        await end_active_for_vehicle(db, vehicle.id, EmergencyEndReason.MANAGER, now, actor=manager, note=note)
        await db.commit()
    return event_out(event, vehicle, now)


async def list_events(db: AsyncSession, limit: int, include_simulated: bool) -> list[EmergencyEventOut]:
    stmt = (
        select(EmergencyEvent, Vehicle)
        .join(Vehicle, Vehicle.id == EmergencyEvent.vehicle_id)
        .order_by(EmergencyEvent.started_at.desc())
        .limit(limit)
    )
    if not include_simulated:
        stmt = stmt.where(Vehicle.is_simulated.is_(False))
    now = utcnow()
    return [event_out(e, v, now) for e, v in (await db.execute(stmt)).all()]


async def list_active(db: AsyncSession, include_simulated: bool = True) -> list[ActiveEmergencyOut]:
    stmt = (
        select(EmergencyEvent, Vehicle, VehicleLiveState)
        .join(Vehicle, Vehicle.id == EmergencyEvent.vehicle_id)
        .outerjoin(VehicleLiveState, VehicleLiveState.vehicle_id == Vehicle.id)
        .where(EmergencyEvent.status == EmergencyEventStatus.ACTIVE)
        .order_by(EmergencyEvent.started_at)
    )
    if not include_simulated:
        stmt = stmt.where(Vehicle.is_simulated.is_(False))
    rows = (await db.execute(stmt)).all()
    if not rows:
        return []
    network, refs = await network_cache.load(db)
    now = utcnow()
    result = []
    for event, vehicle, live in rows:
        base = event_out(event, vehicle, now).model_dump()
        position = dict(lat=None, lon=None, speed_mps=None, heading_deg=None, last_fix_at=None,
                        intersection_code=None, approach_name=None, next_intersection_code=None, eta_s=None)
        if live is not None:
            m = map_observation(
                Observation(key=str(vehicle.id), source=Source(live.source.value), lat=live.lat, lon=live.lon,
                            recorded_at=live.recorded_at, accuracy_m=live.accuracy_m, speed_mps=live.speed_mps,
                            heading_deg=live.heading_deg, emergency=True),
                network,
            )
            position.update(
                lat=live.lat, lon=live.lon, speed_mps=live.speed_mps, heading_deg=live.heading_deg,
                last_fix_at=live.recorded_at, intersection_code=m.intersection_code,
                approach_name=m.approach_name if m.intersection_code else m.link_to_approach,
                next_intersection_code=m.intersection_code if m.zone and m.zone.value in ("APPROACH", "CORE")
                else m.link_to_code,
                eta_s=round(m.eta_s, 1) if m.eta_s is not None else None,
            )
        result.append(ActiveEmergencyOut(**base, **position))
    return result


async def expire(db: AsyncSession, now: datetime) -> int:
    """Housekeeping: end emergencies that lost their vehicle, ran too long or lost authorisation."""
    s = get_settings()
    rows = (
        await db.execute(
            select(EmergencyEvent, Vehicle)
            .join(Vehicle, Vehicle.id == EmergencyEvent.vehicle_id)
            .where(EmergencyEvent.status == EmergencyEventStatus.ACTIVE)
        )
    ).all()
    ended = 0
    for event, vehicle in rows:
        live = await db.get(VehicleLiveState, vehicle.id)
        last_fix = live.recorded_at if live else event.started_at
        reason = None
        if not is_emergency_authorized(vehicle, await latest_authorization(db, vehicle.id), now):
            reason = EmergencyEndReason.AUTH_REVOKED
        elif (now - max(last_fix, event.started_at)).total_seconds() > s.emergency_stale_s:
            reason = EmergencyEndReason.TIMEOUT
        elif now - event.started_at > timedelta(seconds=s.emergency_max_duration_s):
            reason = EmergencyEndReason.TIMEOUT
        if reason is not None:
            await end_active_for_vehicle(db, vehicle.id, reason, now)
            ended += 1
    return ended
