"""Signal plans, advisory decisions and reported states (manager view)."""
import uuid

from fastapi import APIRouter, Depends, Query
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import require_manager
from app.core.time import utcnow
from app.db.session import get_db
from app.models.user import User
from app.schemas.signals import SignalOverviewItem, SignalPlanIn, SignalPlanOut
from app.schemas.traffic import SignalDecisionOut
from app.services import network_cache, signal_service

router = APIRouter(tags=["signals"])


@router.get("/signals/overview", response_model=list[SignalOverviewItem])
async def overview(_: User = Depends(require_manager), db: AsyncSession = Depends(get_db)) -> list[SignalOverviewItem]:
    network, refs = await network_cache.load(db)
    plans = await signal_service.load_plans(db, network, refs)
    now = utcnow()
    items = []
    for code, info in sorted(refs.by_code.items()):
        plan, is_default, updated_at = plans[code]
        items.append(SignalOverviewItem(
            intersection_id=info.id, code=code, name=info.name, controller_type=info.controller_type,
            actuator=info.actuator, connected=signal_service.state_store.connected(code, now),
            plan=signal_service.plan_out(info.id, code, plan, is_default, updated_at),
            decision=await signal_service.latest_valid_decision(db, info.id, code, now),
            state=await signal_service.latest_state(db, info.id, code),
        ))
    return items


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
