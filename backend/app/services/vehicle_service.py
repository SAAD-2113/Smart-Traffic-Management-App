"""Vehicle registration, role-specific views, suspension and device binding."""
import uuid
from datetime import datetime

from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import get_settings
from app.core.errors import AppError, not_found
from app.core.time import utcnow
from app.models.enums import (
    AuthorizationStatus,
    DeviceStatus,
    UserRole,
    VehicleStatus,
    VehicleType,
)
from app.models.user import User
from app.models.vehicle import Device, EmergencyAuthorization, Vehicle
from app.repositories import audit_repo, vehicle_repo
from app.schemas.common import Page
from app.schemas.vehicle import (
    AdminVehicleOut,
    DeviceBindRequest,
    EmergencyAuthorizationOut,
    ManagerVehicleOut,
    OwnerVehicleOut,
    VehicleCreate,
)

PREFIX_NORMAL = "VH"
PREFIX_EMERGENCY = "EV"
PREFIX_SIMULATED = "SIM"


def code_prefix(vehicle_type: VehicleType, is_simulated: bool) -> str:
    if is_simulated:
        return PREFIX_SIMULATED
    return PREFIX_EMERGENCY if vehicle_type.is_emergency else PREFIX_NORMAL


def is_emergency_authorized(
    vehicle: Vehicle, authorization: EmergencyAuthorization | None, now: datetime
) -> bool:
    return (
        vehicle.vehicle_type.is_emergency
        and vehicle.status == VehicleStatus.ACTIVE
        and authorization is not None
        and authorization.status == AuthorizationStatus.APPROVED
        and (authorization.valid_until is None or authorization.valid_until > now)
    )


def to_owner_out(vehicle: Vehicle, auth: EmergencyAuthorization | None, now: datetime) -> OwnerVehicleOut:
    return OwnerVehicleOut(
        id=vehicle.id,
        code=vehicle.code,
        vehicle_type=vehicle.vehicle_type,
        display_name=vehicle.display_name,
        registration_number=vehicle.registration_number,
        is_simulated=vehicle.is_simulated,
        status=vehicle.status,
        emergency_authorization=(
            EmergencyAuthorizationOut(
                status=auth.status, valid_until=auth.valid_until, reviewed_at=auth.reviewed_at
            )
            if auth
            else None
        ),
        emergency_authorized=is_emergency_authorized(vehicle, auth, now),
        created_at=vehicle.created_at,
    )


def to_manager_out(vehicle: Vehicle, auth: EmergencyAuthorization | None, now: datetime) -> ManagerVehicleOut:
    return ManagerVehicleOut(
        id=vehicle.id,
        code=vehicle.code,
        vehicle_type=vehicle.vehicle_type,
        is_simulated=vehicle.is_simulated,
        status=vehicle.status,
        emergency_authorized=is_emergency_authorized(vehicle, auth, now),
        created_at=vehicle.created_at,
    )


async def _latest_auth(db: AsyncSession, vehicle: Vehicle) -> EmergencyAuthorization | None:
    return (await vehicle_repo.latest_authorizations(db, [vehicle.id])).get(vehicle.id)


async def _owned_vehicle(db: AsyncSession, owner: User, vehicle_id: uuid.UUID) -> Vehicle:
    """404 (not 403) for other people's vehicles, so vehicle ids cannot be probed."""
    vehicle = await db.get(Vehicle, vehicle_id)
    if vehicle is None or vehicle.owner_user_id != owner.id:
        raise not_found("Vehicle")
    return vehicle


owned_vehicle = _owned_vehicle


async def register_vehicle(
    db: AsyncSession, owner: User, data: VehicleCreate, *, is_simulated: bool = False
) -> OwnerVehicleOut:
    if owner.role != UserRole.END_USER:
        raise AppError(403, "FORBIDDEN", "Only end-user accounts can register vehicles.")
    limit = get_settings().max_vehicles_per_user
    if await vehicle_repo.count_owned(db, owner.id) >= limit:
        raise AppError(409, "VEHICLE_LIMIT_REACHED", f"An account can register at most {limit} vehicles.")

    code = await vehicle_repo.allocate_code(db, code_prefix(data.vehicle_type, is_simulated))
    vehicle = Vehicle(
        code=code,
        owner_user_id=owner.id,
        vehicle_type=data.vehicle_type,
        display_name=data.display_name,
        registration_number=data.registration_number,
        is_simulated=is_simulated,
    )
    db.add(vehicle)
    await db.flush()

    authorization = None
    if data.vehicle_type.is_emergency and not is_simulated:
        # Registering as an ambulance grants nothing: a manager must verify and approve it.
        authorization = EmergencyAuthorization(
            vehicle_id=vehicle.id, status=AuthorizationStatus.PENDING, requested_by=owner.id
        )
        db.add(authorization)
        await db.flush()

    await audit_repo.record(
        db,
        "vehicle.registered",
        actor_user_id=owner.id,
        target_type="vehicle",
        target_id=vehicle.id,
        details={"code": code, "type": data.vehicle_type.value},
    )
    await db.commit()
    return to_owner_out(vehicle, authorization, utcnow())


async def list_owner_vehicles(db: AsyncSession, owner: User) -> list[OwnerVehicleOut]:
    vehicles = await vehicle_repo.list_owned(db, owner.id)
    auths = await vehicle_repo.latest_authorizations(db, [v.id for v in vehicles])
    now = utcnow()
    return [to_owner_out(v, auths.get(v.id), now) for v in vehicles]


async def get_owner_vehicle(db: AsyncSession, owner: User, vehicle_id: uuid.UUID) -> OwnerVehicleOut:
    vehicle = await _owned_vehicle(db, owner, vehicle_id)
    return to_owner_out(vehicle, await _latest_auth(db, vehicle), utcnow())


async def get_manager_vehicle(db: AsyncSession, vehicle_id: uuid.UUID) -> ManagerVehicleOut:
    vehicle = await db.get(Vehicle, vehicle_id)
    if vehicle is None:
        raise not_found("Vehicle")
    return to_manager_out(vehicle, await _latest_auth(db, vehicle), utcnow())


async def get_admin_vehicle(db: AsyncSession, vehicle_id: uuid.UUID) -> AdminVehicleOut:
    vehicle = await db.get(Vehicle, vehicle_id)
    if vehicle is None:
        raise not_found("Vehicle")
    owner_view = to_owner_out(vehicle, await _latest_auth(db, vehicle), utcnow())
    return AdminVehicleOut(**owner_view.model_dump(), owner_user_id=vehicle.owner_user_id)


async def list_manager_vehicles(
    db: AsyncSession,
    *,
    vehicle_type: VehicleType | None,
    status: VehicleStatus | None,
    is_simulated: bool | None,
    limit: int,
    offset: int,
) -> Page[ManagerVehicleOut]:
    vehicles, total = await vehicle_repo.list_filtered(
        db, vehicle_type=vehicle_type, status=status, is_simulated=is_simulated, limit=limit, offset=offset
    )
    auths = await vehicle_repo.latest_authorizations(db, [v.id for v in vehicles])
    now = utcnow()
    return Page[ManagerVehicleOut](
        items=[to_manager_out(v, auths.get(v.id), now) for v in vehicles],
        total=total,
        limit=limit,
        offset=offset,
    )


async def set_vehicle_status(
    db: AsyncSession, actor: User, vehicle_id: uuid.UUID, status: VehicleStatus, reason: str
) -> ManagerVehicleOut:
    vehicle = await db.get(Vehicle, vehicle_id)
    if vehicle is None:
        raise not_found("Vehicle")
    if vehicle.status == VehicleStatus.RETIRED:
        raise AppError(409, "VEHICLE_RETIRED", "A retired vehicle cannot be changed.")
    previous = vehicle.status
    vehicle.status = status
    if status == VehicleStatus.SUSPENDED and previous != VehicleStatus.SUSPENDED:
        from app.models.enums import EmergencyEndReason, SessionEndReason
        from app.services import tracking_service

        await tracking_service.close_all_for_vehicle(
            db, vehicle.id, SessionEndReason.VEHICLE_SUSPENDED, utcnow(), EmergencyEndReason.VEHICLE_SUSPENDED
        )
    await audit_repo.record(
        db,
        "vehicle.status_changed",
        actor_user_id=actor.id,
        target_type="vehicle",
        target_id=vehicle.id,
        details={"from": previous.value, "to": status.value, "reason": reason},
    )
    await db.commit()
    return to_manager_out(vehicle, await _latest_auth(db, vehicle), utcnow())


async def bind_device(
    db: AsyncSession, owner: User, vehicle_id: uuid.UUID, data: DeviceBindRequest
) -> Device:
    """Make this app installation the vehicle's single active device.

    Rules: one active device per vehicle, and one installation is active on only one
    vehicle at a time (a phone moved to another vehicle stops reporting for the old one).
    """
    vehicle = await _owned_vehicle(db, owner, vehicle_id)
    if vehicle.status != VehicleStatus.ACTIVE:
        raise AppError(409, "VEHICLE_NOT_ACTIVE", "This vehicle is not active.")

    now = utcnow()
    # Deactivate first (separate statements) so the partial unique index is never violated.
    await db.execute(
        update(Device)
        .where(
            Device.vehicle_id == vehicle.id,
            Device.status == DeviceStatus.ACTIVE,
            Device.installation_id != data.installation_id,
        )
        .values(status=DeviceStatus.INACTIVE, unbound_at=now)
    )
    await db.execute(
        update(Device)
        .where(
            Device.installation_id == data.installation_id,
            Device.vehicle_id != vehicle.id,
            Device.status == DeviceStatus.ACTIVE,
        )
        .values(status=DeviceStatus.INACTIVE, unbound_at=now)
    )

    device = await db.scalar(
        select(Device).where(
            Device.vehicle_id == vehicle.id, Device.installation_id == data.installation_id
        )
    )
    if device is None:
        device = Device(
            vehicle_id=vehicle.id,
            installation_id=data.installation_id,
            platform=data.platform,
            model=data.model,
            app_version=data.app_version,
            status=DeviceStatus.ACTIVE,
            bound_at=now,
        )
        db.add(device)
    else:
        if device.status != DeviceStatus.ACTIVE:
            device.bound_at = now
        device.status = DeviceStatus.ACTIVE
        device.unbound_at = None
        device.platform = data.platform
        device.model = data.model
        device.app_version = data.app_version
    await db.flush()

    await audit_repo.record(
        db,
        "device.bound",
        actor_user_id=owner.id,
        target_type="vehicle",
        target_id=vehicle.id,
        details={"deviceId": str(device.id)},
    )
    await db.commit()
    return device


async def list_devices(db: AsyncSession, owner: User, vehicle_id: uuid.UUID) -> list[Device]:
    vehicle = await _owned_vehicle(db, owner, vehicle_id)
    rows = await db.scalars(
        select(Device).where(Device.vehicle_id == vehicle.id).order_by(Device.bound_at.desc())
    )
    return list(rows)


async def unbind_device(
    db: AsyncSession, owner: User, vehicle_id: uuid.UUID, device_id: uuid.UUID
) -> None:
    vehicle = await _owned_vehicle(db, owner, vehicle_id)
    device = await db.get(Device, device_id)
    if device is None or device.vehicle_id != vehicle.id:
        raise not_found("Device")
    if device.status == DeviceStatus.ACTIVE:
        device.status = DeviceStatus.INACTIVE
        device.unbound_at = utcnow()
        await audit_repo.record(
            db,
            "device.unbound",
            actor_user_id=owner.id,
            target_type="vehicle",
            target_id=vehicle.id,
            details={"deviceId": str(device.id)},
        )
        await db.commit()
