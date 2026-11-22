"""Digital V2I accounts and sessions. Roles come from the database: ADMIN / MANAGER accounts host
a digital intersection, END_USER accounts join one as vehicles with its code."""
import secrets
import uuid

from sqlalchemy import func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.errors import AppError, not_found
from app.core.time import utcnow
from app.models.enums import UserRole, V2IEmergencyStatus, V2ISessionStatus
from app.models.user import User
from app.models.v2i import V2IExport, V2IMember, V2IProfile, V2ISession
from app.realtime.v2i_relay import relay
from app.repositories import audit_repo, user_repo
from app.schemas.v2i import (
    EmergencyDecisionIn,
    ExportIn,
    ExportOut,
    JoinedOut,
    ProfileOut,
    SessionCreateIn,
    SessionOut,
    SessionStateOut,
    V2IMeOut,
)

VEHICLE_ID_MIN = 1001  # 101..202 stay reserved for the hardware presets
VEHICLE_ID_MAX = 65535
JOIN_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"  # no 0/O, 1/I
JOIN_CODE_LEN = 6
HOST_ROLES = (UserRole.ADMIN, UserRole.MANAGER)


def can_host(user: User) -> bool:
    return user.role in HOST_ROLES


async def get_or_create_profile(db: AsyncSession, user: User) -> V2IProfile:
    """The account's V2I vehicle id is assigned here, once, by the server."""
    if user.role != UserRole.END_USER:
        raise AppError(403, "FORBIDDEN", "Only driver accounts have a V2I vehicle.")
    for _ in range(5):
        profile = await db.get(V2IProfile, user.id)
        if profile is not None:
            return profile
        top = await db.scalar(select(func.max(V2IProfile.vehicle_id)))
        vid = max(VEHICLE_ID_MIN, (top or 0) + 1)
        if vid > VEHICLE_ID_MAX:
            raise AppError(409, "V2I_IDS_EXHAUSTED", "No V2I vehicle ids are left.")
        db.add(V2IProfile(user_id=user.id, vehicle_id=vid, emergency_status=V2IEmergencyStatus.NONE))
        try:
            await db.commit()
        except IntegrityError:
            await db.rollback()  # another request took that id (or created this profile): try again
    raise AppError(503, "V2I_BUSY", "Please try again.")


async def me(db: AsyncSession, user: User) -> V2IMeOut:
    out = V2IMeOut(role=user.role.value, can_host=can_host(user), can_drive=user.role == UserRole.END_USER)
    if out.can_drive:
        p = await get_or_create_profile(db, user)
        out.vehicle_id, out.emergency_status, out.emergency = p.vehicle_id, p.emergency_status, p.emergency
    return out


async def request_emergency(db: AsyncSession, user: User, reason: str) -> V2IMeOut:
    p = await get_or_create_profile(db, user)
    if p.emergency_status in (V2IEmergencyStatus.APPROVED, V2IEmergencyStatus.REQUESTED):
        raise AppError(409, "ALREADY_" + p.emergency_status.value, f"The request is already {p.emergency_status.value.lower()}.")
    p.emergency_status = V2IEmergencyStatus.REQUESTED
    p.emergency_reason = reason or None
    p.emergency_requested_at = utcnow()
    await audit_repo.record(db, "v2i.emergency.requested", actor_user_id=user.id, target_type="v2i_profile", target_id=user.id)
    await db.commit()
    return await me(db, user)


async def decide_emergency(db: AsyncSession, admin: User, body: EmergencyDecisionIn) -> ProfileOut:
    if body.status not in (V2IEmergencyStatus.APPROVED, V2IEmergencyStatus.REJECTED, V2IEmergencyStatus.REVOKED):
        raise AppError(422, "INVALID_STATUS", "Set APPROVED, REJECTED or REVOKED.")
    user = await user_repo.get_by_email(db, body.email)
    if user is None:
        raise not_found("User")
    if user.role != UserRole.END_USER:
        raise AppError(409, "NOT_A_DRIVER", "Only driver accounts can be emergency vehicles.")
    p = await get_or_create_profile(db, user)
    p.emergency_status = body.status
    p.emergency_decided_at = utcnow()
    p.emergency_decided_by = admin.id
    await audit_repo.record(db, "v2i.emergency." + body.status.value.lower(), actor_user_id=admin.id,
                            target_type="v2i_profile", target_id=user.id)
    await db.commit()
    await relay.set_emergency(user.id, p.emergency)
    return _profile_out(p, user)


def _profile_out(p: V2IProfile, u: User) -> ProfileOut:
    return ProfileOut(
        user_id=u.id, full_name=u.full_name, email=u.email, vehicle_id=p.vehicle_id,
        emergency_status=p.emergency_status, emergency_reason=p.emergency_reason,
        emergency_requested_at=p.emergency_requested_at, emergency_decided_at=p.emergency_decided_at,
    )


async def list_profiles(db: AsyncSession, status: V2IEmergencyStatus | None, limit: int) -> list[ProfileOut]:
    q = select(V2IProfile, User).join(User, User.id == V2IProfile.user_id)
    if status is not None:
        q = q.where(V2IProfile.emergency_status == status)
    q = q.order_by(V2IProfile.emergency_requested_at.desc().nulls_last(), V2IProfile.vehicle_id).limit(limit)
    return [_profile_out(p, u) for p, u in (await db.execute(q)).all()]


# --- sessions --------------------------------------------------------------------------------

async def _members(db: AsyncSession, session_id: uuid.UUID) -> int:
    return await db.scalar(select(func.count()).select_from(V2IMember).where(V2IMember.session_id == session_id)) or 0


async def session_out(db: AsyncSession, s: V2ISession) -> SessionOut:
    return SessionOut(
        id=s.id, name=s.name, join_code=s.join_code, center_lat=s.center_lat, center_lon=s.center_lon,
        status=s.status, created_at=s.created_at, closed_at=s.closed_at, members=await _members(db, s.id),
        online_vehicles=relay.online_vehicles(s.id), intersection_online=relay.intersection_online(s.id),
    )


async def create_session(db: AsyncSession, host: User, body: SessionCreateIn) -> SessionOut:
    existing = await db.scalar(
        select(V2ISession).where(V2ISession.host_user_id == host.id, V2ISession.status == V2ISessionStatus.OPEN)
    )
    if existing is not None:
        raise AppError(409, "SESSION_ALREADY_OPEN", "Close your open session first.",
                       details=[{"sessionId": str(existing.id)}])
    for _ in range(10):
        code = "".join(secrets.choice(JOIN_ALPHABET) for _ in range(JOIN_CODE_LEN))
        if await db.scalar(select(V2ISession.id).where(V2ISession.join_code == code)) is None:
            break
    else:
        raise AppError(503, "V2I_BUSY", "Please try again.")
    s = V2ISession(name=body.name, join_code=code, host_user_id=host.id, center_lat=body.center_lat,
                   center_lon=body.center_lon, status=V2ISessionStatus.OPEN, created_at=utcnow())
    db.add(s)
    await audit_repo.record(db, "v2i.session.created", actor_user_id=host.id, target_type="v2i_session", target_id=s.id)
    await db.commit()
    return await session_out(db, s)


async def my_sessions(db: AsyncSession, host: User, include_closed: bool) -> list[SessionOut]:
    q = select(V2ISession).where(V2ISession.host_user_id == host.id)
    if not include_closed:
        q = q.where(V2ISession.status == V2ISessionStatus.OPEN)
    rows = (await db.scalars(q.order_by(V2ISession.created_at.desc()).limit(50))).all()
    return [await session_out(db, s) for s in rows]


async def _session(db: AsyncSession, session_id: uuid.UUID) -> V2ISession:
    s = await db.get(V2ISession, session_id)
    if s is None:
        raise not_found("Session")
    return s


async def host_session(db: AsyncSession, user: User, session_id: uuid.UUID) -> V2ISession:
    """The session if [user] hosts it (or is an admin); 404 otherwise, so ids cannot be probed."""
    s = await _session(db, session_id)
    if s.host_user_id != user.id and user.role != UserRole.ADMIN:
        raise not_found("Session")
    return s


async def close_session(db: AsyncSession, user: User, session_id: uuid.UUID) -> SessionOut:
    s = await host_session(db, user, session_id)
    if s.status == V2ISessionStatus.OPEN:
        s.status, s.closed_at = V2ISessionStatus.CLOSED, utcnow()
        await audit_repo.record(db, "v2i.session.closed", actor_user_id=user.id, target_type="v2i_session", target_id=s.id)
        await db.commit()
        await relay.close_session(s.id)
    return await session_out(db, s)


async def join(db: AsyncSession, user: User, code: str) -> JoinedOut:
    p = await get_or_create_profile(db, user)
    s = await db.scalar(
        select(V2ISession).where(V2ISession.join_code == code.strip().upper(), V2ISession.status == V2ISessionStatus.OPEN)
    )
    if s is None:
        raise AppError(404, "NO_SUCH_SESSION", "No open session has this code.")
    member = await db.scalar(select(V2IMember).where(V2IMember.session_id == s.id, V2IMember.user_id == user.id))
    if member is None:
        db.add(V2IMember(session_id=s.id, user_id=user.id, joined_at=utcnow()))
        await audit_repo.record(db, "v2i.session.joined", actor_user_id=user.id, target_type="v2i_session", target_id=s.id)
        await db.commit()
    return _joined(s, p)


def _joined(s: V2ISession, p: V2IProfile) -> JoinedOut:
    return JoinedOut(session_id=s.id, name=s.name, center_lat=s.center_lat, center_lon=s.center_lon,
                     vehicle_id=p.vehicle_id, emergency=p.emergency, intersection_online=relay.intersection_online(s.id))


async def joined_sessions(db: AsyncSession, user: User) -> list[JoinedOut]:
    p = await get_or_create_profile(db, user)
    rows = (await db.scalars(
        select(V2ISession).join(V2IMember, V2IMember.session_id == V2ISession.id)
        .where(V2IMember.user_id == user.id, V2ISession.status == V2ISessionStatus.OPEN)
        .order_by(V2IMember.joined_at.desc()).limit(20)
    )).all()
    return [_joined(s, p) for s in rows]


async def session_state(db: AsyncSession, user: User, session_id: uuid.UUID) -> SessionStateOut:
    """Latest state JSON of the intersection, for its host and for managers (not for vehicles)."""
    s = await _session(db, session_id)
    if s.host_user_id != user.id and user.role not in HOST_ROLES:
        raise not_found("Session")
    room = relay.rooms.get(s.id)
    return SessionStateOut(session_id=s.id, intersection_online=relay.intersection_online(s.id),
                           received_at=room.state_at if room else None, state=room.state if room else None)


async def upload_export(db: AsyncSession, user: User, session_id: uuid.UUID, body: ExportIn) -> ExportOut:
    """Server copy of an export, by the session's host (or an admin)."""
    s = await host_session(db, user, session_id)
    e = V2IExport(session_id=s.id, uploaded_by=user.id, filename=body.filename, content_type=body.content_type,
                  size=len(body.content.encode("utf-8")), content=body.content, created_at=utcnow())
    db.add(e)
    await audit_repo.record(db, "v2i.export.uploaded", actor_user_id=user.id, target_type="v2i_session", target_id=s.id,
                            details={"filename": body.filename, "size": e.size})
    await db.commit()
    return ExportOut.model_validate(e)


async def list_exports(db: AsyncSession, user: User, session_id: uuid.UUID) -> list[ExportOut]:
    s = await host_session(db, user, session_id)
    rows = (await db.scalars(select(V2IExport).where(V2IExport.session_id == s.id)
                             .order_by(V2IExport.created_at.desc()).limit(200))).all()
    return [ExportOut.model_validate(e) for e in rows]


async def get_export(db: AsyncSession, user: User, export_id: uuid.UUID) -> V2IExport:
    e = await db.get(V2IExport, export_id)
    if e is None:
        raise not_found("Export")
    await host_session(db, user, e.session_id)  # 404 unless host or admin
    return e


async def relay_role(db: AsyncSession, user: User, session_id: uuid.UUID) -> tuple[V2ISession, str, V2IProfile | None]:
    """Who [user] is in the relay, decided from the database: the host's phone is the
    intersection, a member's phone a vehicle. Raises 404 / 403."""
    s = await db.get(V2ISession, session_id)
    if s is None or s.status != V2ISessionStatus.OPEN:
        raise AppError(404, "NO_SUCH_SESSION", "No open session.")
    if s.host_user_id == user.id and can_host(user):
        return s, "intersection", None
    if user.role == UserRole.END_USER:
        member = await db.scalar(select(V2IMember).where(V2IMember.session_id == s.id, V2IMember.user_id == user.id))
        if member is not None:
            return s, "vehicle", await get_or_create_profile(db, user)
    raise AppError(403, "FORBIDDEN", "Join the session with its code first.")
