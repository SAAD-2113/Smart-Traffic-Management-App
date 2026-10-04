"""Signal plans, advisory decisions and reported states (manager view)."""
import uuid

from fastapi import APIRouter, Depends, Query
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.api.deps import require_manager
from app.core.time import utcnow
from app.db.session import get_db, get_session_factory
from app.models.user import User
from app.schemas.signals import ControlConfigOut, ModeEventOut, SignalOverviewItem, SignalPlanIn, SignalPlanOut
from app.schemas.traffic import SignalDecisionOut
from app.services import live_service, network_cache, signal_service

router = APIRouter(tags=["signals"])


@router.get("/signals/overview", response_model=list[SignalOverviewItem])
async def overview(
    _: User = Depends(require_manager),
    db: AsyncSession = Depends(get_db),
    factory: async_sessionmaker = Depends(get_session_factory),
) -> list[SignalOverviewItem]:
    snapshot = await live_service.current_snapshot(factory)
    network, refs = await network_cache.load(db)
    plans = await signal_service.load_plans(db, network, refs)
    now = utcnow()
    items = []
    for code, info in sorted(refs.by_code.items()):
        plan, is_default, updated_at = plans[code]
        items.append(SignalOverviewItem(
            intersection_id=info.id, code=code, name=info.name, controller_type=info.controller_type,
            actuator=info.actuator, connected=signal_service.state_store.connected(code, now),
            plan=signal_service.plan_out(info.id, code, plan, is_default, updated_at, network.intersections[code]),
            decision=await signal_service.latest_valid_decision(db, info.id, code, now),
            state=await signal_service.latest_state(db, info.id, code),
            control=live_service.control_status(snapshot, code),
            display_signal=live_service.display_signal(snapshot, code, info, now),
        ))
    return items


@router.get("/signals/control-config", response_model=ControlConfigOut)
async def control_config(_: User = Depends(require_manager)) -> ControlConfigOut:
    return signal_service.control_config()


@router.get("/signals/mode-events", response_model=list[ModeEventOut])
async def mode_events(
    intersection_id: uuid.UUID | None = Query(default=None, alias="intersectionId"),
    limit: int = Query(default=50, ge=1, le=500),
    _: User = Depends(require_manager),
    db: AsyncSession = Depends(get_db),
) -> list[ModeEventOut]:
    return await signal_service.mode_events(db, intersection_id, limit)


@router.get("/intersections/{intersection_id}/signal-plan", response_model=SignalPlanOut)
async def get_plan(
    intersection_id: uuid.UUID, _: User = Depends(require_manager), db: AsyncSession = Depends(get_db)
) -> SignalPlanOut:
    return await signal_service.get_plan(db, intersection_id)


@router.put("/intersections/{intersection_id}/signal-plan", response_model=SignalPlanOut)
async def put_plan(
    intersection_id: uuid.UUID, body: SignalPlanIn,
    user: User = Depends(require_manager), db: AsyncSession = Depends(get_db),
) -> SignalPlanOut:
    return await signal_service.put_plan(db, user, intersection_id, body)


@router.get("/intersections/{intersection_id}/signal-decisions", response_model=list[SignalDecisionOut])
async def decisions(
    intersection_id: uuid.UUID,
    limit: int = Query(default=20, ge=1, le=200),
    _: User = Depends(require_manager),
    db: AsyncSession = Depends(get_db),
) -> list[SignalDecisionOut]:
    return await signal_service.recent_decisions(db, intersection_id, limit)
