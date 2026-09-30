"""Read models for live monitoring: vehicle states, overview, intersection traffic, snapshots."""
import uuid
from datetime import datetime, timedelta

from sqlalchemy import func, select, text
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.core.config import get_settings
from app.core.errors import not_found
from app.core.time import utcnow
from app.models.emergency import EmergencyEvent
from app.models.enums import EmergencyEventStatus, IntersectionStatus, VehicleStatus
from app.models.telemetry import TrackingSession, VehicleLiveState, VehicleTelemetry
from app.models.user import User
from app.models.vehicle import Vehicle
from app.realtime.hub import hub
from app.repositories import vehicle_repo
from app.schemas.telemetry import LiveStateOut, LiveVehicleOut, OwnerLatestOut, TelemetryPointOut
from app.schemas.traffic import IntersectionTrafficOut, OverviewOut, SystemStatusOut
from app.services import emergency_service, network_cache, signal_service, tracking_service, traffic_views
from app.services.demo_service import demo
from app.services.external_sources import external_store
from app.services.network_cache import NetworkRefs
from app.services.vehicle_service import is_emergency_authorized

ACTIVE_WITHIN_S = 300.0


def live_state_out(live: VehicleLiveState, refs: NetworkRefs, now: datetime) -> LiveStateOut:
    info = refs.by_id.get(live.intersection_id) if live.intersection_id else None
    return LiveStateOut(
        recorded_at=live.recorded_at, received_at=live.received_at,
        age_s=round(max(0.0, (now - live.recorded_at).total_seconds()), 1),
        lat=live.lat, lon=live.lon, accuracy_m=live.accuracy_m, gps_quality=live.gps_quality,
        speed_mps=live.speed_mps, heading_deg=live.heading_deg, emergency=live.emergency, usable=live.usable,
        source=live.source, intersection_code=info.code if info else None,
        approach_name=refs.approach_names.get(live.approach_id) if live.approach_id else None,
        zone=live.zone,
    )


async def _open_sessions(db: AsyncSession, vehicle_ids: list[uuid.UUID]) -> dict[uuid.UUID, TrackingSession]:
    if not vehicle_ids:
        return {}
    rows = await db.scalars(
        select(TrackingSession).where(TrackingSession.vehicle_id.in_(vehicle_ids), TrackingSession.ended_at.is_(None))
    )
    return {s.vehicle_id: s for s in rows}


async def _active_event_vehicle_ids(db: AsyncSession) -> set[uuid.UUID]:
    rows = await db.scalars(
        select(EmergencyEvent.vehicle_id).where(EmergencyEvent.status == EmergencyEventStatus.ACTIVE)
    )
    return set(rows)


async def live_vehicles(
    db: AsyncSession, *, include_simulated: bool = True, only_active: bool = True, now: datetime | None = None,
) -> list[LiveVehicleOut]:
    now = now or utcnow()
    stmt = (
        select(Vehicle, VehicleLiveState)
        .outerjoin(VehicleLiveState, VehicleLiveState.vehicle_id == Vehicle.id)
        .where(Vehicle.status != VehicleStatus.RETIRED)
        .order_by(Vehicle.code)
    )
    if not include_simulated:
        stmt = stmt.where(Vehicle.is_simulated.is_(False))
    rows = (await db.execute(stmt)).all()
    sessions = await _open_sessions(db, [v.id for v, _ in rows])
    emergencies = await _active_event_vehicle_ids(db)
    auths = await vehicle_repo.latest_authorizations(db, [v.id for v, _ in rows if v.vehicle_type.is_emergency])
    _, refs = await network_cache.load(db)

    result = []
    for vehicle, live in rows:
        session = sessions.get(vehicle.id)
        recent = live is not None and (now - live.recorded_at).total_seconds() <= ACTIVE_WITHIN_S
        if only_active and session is None and not recent:
            continue
        result.append(LiveVehicleOut(
            vehicle_id=vehicle.id, code=vehicle.code, vehicle_type=vehicle.vehicle_type,
            is_simulated=vehicle.is_simulated,
            emergency_authorized=is_emergency_authorized(vehicle, auths.get(vehicle.id), now),
            emergency_active=vehicle.id in emergencies,
            tracking_status=tracking_service.tracking_status(session, live, now),
            live=live_state_out(live, refs, now) if live is not None else None,
        ))
    return result


async def live_vehicle(db: AsyncSession, vehicle_id: uuid.UUID) -> LiveVehicleOut:
    vehicle = await db.get(Vehicle, vehicle_id)
    if vehicle is None:
        raise not_found("Vehicle")
    now = utcnow()
    live = await db.get(VehicleLiveState, vehicle.id)
    session = await tracking_service.open_session(db, vehicle.id)
    _, refs = await network_cache.load(db)
    return LiveVehicleOut(
        vehicle_id=vehicle.id, code=vehicle.code, vehicle_type=vehicle.vehicle_type,
        is_simulated=vehicle.is_simulated,
        emergency_authorized=is_emergency_authorized(
            vehicle, await emergency_service.latest_authorization(db, vehicle.id), now
        ),
        emergency_active=await emergency_service.active_event(db, vehicle.id) is not None,
        tracking_status=tracking_service.tracking_status(session, live, now),
        live=live_state_out(live, refs, now) if live else None,
    )


async def vehicle_track(db: AsyncSession, vehicle_id: uuid.UUID, minutes: int, limit: int) -> list[TelemetryPointOut]:
    vehicle = await db.get(Vehicle, vehicle_id)
    if vehicle is None:
        raise not_found("Vehicle")
    since = utcnow() - timedelta(minutes=minutes)
    rows = list(await db.scalars(
        select(VehicleTelemetry)
        .where(VehicleTelemetry.vehicle_id == vehicle.id, VehicleTelemetry.recorded_at >= since)
        .order_by(VehicleTelemetry.recorded_at.desc())
        .limit(limit)
    ))
    rows.reverse()
    return [
        TelemetryPointOut(recorded_at=r.recorded_at, lat=r.lat, lon=r.lon, accuracy_m=r.accuracy_m,
                          speed_mps=r.speed_mps, heading_deg=r.heading_deg, emergency=r.emergency,
                          is_live=r.is_live, usable=r.usable, zone=r.zone)
        for r in rows
    ]


async def owner_latest(db: AsyncSession, owner: User, vehicle_id: uuid.UUID) -> OwnerLatestOut:
    from app.services import vehicle_service

    vehicle = await vehicle_service.owned_vehicle(db, owner, vehicle_id)
    now = utcnow()
    live = await db.get(VehicleLiveState, vehicle.id)
    session = await tracking_service.open_session(db, vehicle.id)
    _, refs = await network_cache.load(db)
    return OwnerLatestOut(
        vehicle_id=vehicle.id,
        tracking_status=tracking_service.tracking_status(session, live, now),
        session=tracking_service.to_out(session, now) if session else None,
        live=live_state_out(live, refs, now) if live else None,
        emergency_active=await emergency_service.active_event(db, vehicle.id) is not None,
    )


# -- traffic ---------------------------------------------------------------------------

async def intersections_traffic(db: AsyncSession, snapshot, now: datetime) -> list[IntersectionTrafficOut]:
    result = []
    for code, info in sorted(snapshot.refs.by_code.items()):
        decision = await signal_service.latest_valid_decision(db, info.id, code, now)
        result.append(traffic_views.intersection_out(
            info, snapshot.state.intersections.get(code),
            signal=await signal_service.latest_state(db, info.id, code),
            connected=signal_service.state_store.connected(code, now),
            decision=decision, computed_at=snapshot.computed_at,
        ))
    return result


async def overview(db: AsyncSession, snapshot, now: datetime) -> OverviewOut:
    from app.services.runner import runner

    window = get_settings().live_window_s
    total_real = await db.scalar(select(func.count()).select_from(Vehicle).where(
        Vehicle.is_simulated.is_(False), Vehicle.status != VehicleStatus.RETIRED)) or 0
    total_sim = await db.scalar(select(func.count()).select_from(Vehicle).where(Vehicle.is_simulated.is_(True))) or 0
    active = await db.scalar(select(func.count()).select_from(TrackingSession).where(
        TrackingSession.ended_at.is_(None))) or 0
    fresh = list(await db.scalars(select(VehicleLiveState).where(
        VehicleLiveState.recorded_at >= now - timedelta(seconds=window))))
    speeds = [s.speed_mps for s in fresh if s.speed_mps is not None]
    emergencies = await db.scalar(select(func.count()).select_from(EmergencyEvent).where(
        EmergencyEvent.status == EmergencyEventStatus.ACTIVE)) or 0

    states = snapshot.state.intersections
    densities = [s.metrics.density_veh_per_km_lane for s in states.values()
                 if s.metrics.density_veh_per_km_lane is not None]
    congested = sorted(snapshot.state.congested_codes())
    try:
        await db.execute(text("SELECT 1"))
        database = "ok"
    except Exception:
        database = "unavailable"
    infos = snapshot.refs.by_code.values()
    return OverviewOut(
        generated_at=now,
        total_registered_vehicles=total_real,
        simulated_vehicles=total_sim,
        active_vehicles=active,
        transmitting_vehicles=len(fresh),
        emergency_vehicles=emergencies,
        average_speed_mps=round(sum(speeds) / len(speeds), 2) if speeds else None,
        average_density_veh_per_km_lane=round(sum(densities) / len(densities), 1) if densities else None,
        total_intersections=len(snapshot.refs.by_code),
        active_intersections=sum(1 for i in infos if i.status == IntersectionStatus.ACTIVE),
        connected_intersections=sum(1 for c in snapshot.refs.by_code if signal_service.state_store.connected(c, now)),
        congested_intersections=len(congested),
        congested_intersection_codes=congested,
        pending_authorizations=await emergency_service.count_pending(db),
        system=SystemStatusOut(
            database=database, engine_running=runner.running,
            engine_last_cycle_at=runner.latest.computed_at if runner.latest else None,
            engine_cycle_ms=runner.latest.cycle_ms if runner.latest else None,
            websocket_clients=hub.client_count, demo_mode=get_settings().demo_mode,
            simulation_running=demo.running, live_window_s=window,
            external_sources=external_store.active_sources(now),
        ),
    )


async def snapshot_message(db: AsyncSession, snapshot, now: datetime) -> dict:
    """The WebSocket message pushed to manager dashboards after each engine cycle."""
    vehicles = await live_vehicles(db, include_simulated=True, only_active=True, now=now)
    return {
        "type": "snapshot",
        "serverTime": now.isoformat(),
        "summary": (await overview(db, snapshot, now)).model_dump(mode="json", by_alias=True),
        "vehicles": [v.model_dump(mode="json", by_alias=True) for v in vehicles],
        "intersections": [
            i.model_dump(mode="json", by_alias=True) for i in await intersections_traffic(db, snapshot, now)
        ],
        "emergencies": [
            e.model_dump(mode="json", by_alias=True) for e in await emergency_service.list_active(db)
        ],
    }


async def current_snapshot(factory: async_sessionmaker):
    from app.services.runner import runner

    return await runner.current(factory)
