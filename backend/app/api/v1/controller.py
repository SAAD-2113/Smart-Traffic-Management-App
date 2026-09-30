"""Machine clients (Raspberry Pi controllers, SUMO bridge, cameras). Auth: X-Controller-Key.

Every call is limited to the intersections in the key's scope.
"""
from fastapi import APIRouter, Depends, Request
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker
from traffic_engine import DetectorCount, Observation

from app.api.deps import get_controller_client
from app.core.errors import AppError
from app.core.rate_limit import limiter
from app.core.time import utcnow
from app.db.session import get_db, get_session_factory
from app.models.enums import ControllerClientKind
from app.models.system import ControllerClient
from app.schemas.controller import ControllerPingOut, ObservationBatch, ObservationBatchResult
from app.schemas.signals import ControllerDecisionsOut, SignalStateBatch
from app.schemas.traffic import IntersectionTrafficOut
from app.services import live_service, network_cache, signal_service
from app.services.external_sources import KIND_TO_SOURCE, external_store

router = APIRouter(prefix="/controller", tags=["controller (machine clients)"])


def _scope(client: ControllerClient) -> dict[str, object]:
    return {i.code: i for i in client.intersections}


@router.get("/ping", response_model=ControllerPingOut)
async def ping(client: ControllerClient = Depends(get_controller_client)) -> ControllerPingOut:
    """Lets a Raspberry Pi verify its key, its scope and its internet path to the backend."""
    return ControllerPingOut(
        client_id=client.id,
        name=client.name,
        intersection_codes=sorted(i.code for i in client.intersections),
        server_time=utcnow(),
    )


@router.get("/decisions", response_model=ControllerDecisionsOut)
@limiter.limit("120/minute")
async def decisions(
    request: Request, client: ControllerClient = Depends(get_controller_client), db: AsyncSession = Depends(get_db)
) -> ControllerDecisionsOut:
    """Latest valid advisory decision and the plan for each intersection in scope.

    A missing decision means: run the local fixed plan. Ignore any decision after validUntil.
    """
    network, refs = await network_cache.load(db)
    plans = await signal_service.load_plans(db, network, refs)
    now = utcnow()
    out_decisions, out_plans = [], []
    for code in sorted(_scope(client)):
        info = refs.by_code.get(code)
        if info is None:
            continue
        plan, is_default, updated_at = plans[code]
        out_plans.append(signal_service.plan_out(info.id, code, plan, is_default, updated_at))
        decision = await signal_service.latest_valid_decision(db, info.id, code, now)
        if decision is not None:
            out_decisions.append(decision)
    return ControllerDecisionsOut(server_time=now, decisions=out_decisions, plans=out_plans)


@router.get("/traffic-state", response_model=list[IntersectionTrafficOut])
async def traffic_state(
    client: ControllerClient = Depends(get_controller_client),
    db: AsyncSession = Depends(get_db),
    factory: async_sessionmaker = Depends(get_session_factory),
) -> list[IntersectionTrafficOut]:
    scope = _scope(client)
    snapshot = await live_service.current_snapshot(factory)
    return [i for i in await live_service.intersections_traffic(db, snapshot, utcnow()) if i.code in scope]


@router.post("/signal-states", status_code=204)
@limiter.limit("240/minute")
async def signal_states(
    request: Request,
    body: SignalStateBatch,
    client: ControllerClient = Depends(get_controller_client),
    db: AsyncSession = Depends(get_db),
) -> None:
    scope = _scope(client)
    now = utcnow()
    for report in body.states:
        intersection = scope.get(report.intersection_code)
        if intersection is None:
            raise AppError(403, "OUT_OF_SCOPE", f"This key may not report for {report.intersection_code}.")
        if report.reported_at is not None and abs((now - report.reported_at).total_seconds()) > 300:
            raise AppError(422, "CLOCK_SKEW", "reportedAt is more than 5 minutes from server time. Check NTP.")
    for report in body.states:
        intersection = scope[report.intersection_code]
        await signal_service.state_store.record(
            db, intersection.id, intersection.code, report, client_id=client.id, source=client.kind.value, now=now
        )
    await db.commit()


@router.post("/observations", response_model=ObservationBatchResult)
@limiter.limit("240/minute")
async def observations(
    request: Request,
    body: ObservationBatch,
    client: ControllerClient = Depends(get_controller_client),
) -> ObservationBatchResult:
    """Vehicle positions from SUMO or counts from cameras/sensors, for the traffic engine.

    Only a SUMO bridge may flag vehicles as emergency; the flag only ever affects the
    simulated intersections in its scope.
    """
    source = KIND_TO_SOURCE[client.kind]
    now = utcnow()
    observed_at = body.observed_at or now
    if abs((now - observed_at).total_seconds()) > 30:
        raise AppError(422, "CLOCK_SKEW", "observedAt is more than 30 s from server time.")
    scope = _scope(client)
    allow_emergency = client.kind == ControllerClientKind.SUMO_BRIDGE
    vehicles = [
        Observation(
            key=f"{source.value.lower()}:{client.id}:{v.external_id}", source=source, lat=v.lat, lon=v.lon,
            recorded_at=observed_at, accuracy_m=v.accuracy_m, speed_mps=v.speed_mps, heading_deg=v.heading_deg,
            emergency=v.emergency and allow_emergency, vehicle_type=v.vehicle_type, label=v.external_id,
        )
        for v in body.vehicles
    ]
    counts = [
        DetectorCount(c.intersection_code, c.approach_name, c.vehicle_count, observed_at, source, c.queue_length_m)
        for c in body.counts if c.intersection_code in scope
    ]
    external_store.put(client.id, source, frozenset(scope), now, vehicles, counts)
    return ObservationBatchResult(
        accepted_vehicles=len(vehicles), accepted_counts=len(counts),
        ignored_counts=len(body.counts) - len(counts), source=source.value,
    )
