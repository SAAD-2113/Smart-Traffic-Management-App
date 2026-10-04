"""Signal plans (configuration), advisory decisions (engine output) and reported signal states."""
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from traffic_engine import Network
from traffic_engine.control import Phase, SignalDecision, SignalPlan, default_plan

from app.core.errors import AppError, not_found
from app.core.time import utcnow
from app.models.intersection import Intersection
from app.core.config import get_settings
from app.models.traffic import SignalDecisionRecord, SignalModeEvent, SignalPlanConfig, SignalStateRecord
from app.models.user import User
from app.repositories import audit_repo
from app.schemas.signals import (
    ControlConfigOut,
    ModeEventOut,
    PhaseOut,
    SignalPlanIn,
    SignalPlanOut,
    SignalStateReport,
)
from app.schemas.traffic import PhaseGreenOut, SignalDecisionOut, SignalStateOut, TrafficBasisOut
from app.services import network_cache
from app.services.network_cache import NetworkRefs

CONNECTED_WITHIN_S = 30.0
STATE_HEARTBEAT_S = 30.0


# -- plans ---------------------------------------------------------------------------

def plan_from_config(config: SignalPlanConfig) -> SignalPlan:
    return SignalPlan(
        phases=tuple(
            Phase(
                name=p["name"], approaches=tuple(p.get("approaches", [])), min_green_s=p["minGreenS"],
                max_green_s=p["maxGreenS"], fixed_green_s=p["fixedGreenS"], yellow_s=p["yellowS"],
                all_red_s=p["allRedS"],
            )
            for p in config.phases
        ),
        min_cycle_s=config.min_cycle_s,
        max_cycle_s=config.max_cycle_s,
    )


def plan_out(intersection_id: uuid.UUID, code: str, plan: SignalPlan, is_default: bool,
             updated_at: datetime | None, node=None) -> SignalPlanOut:
    return SignalPlanOut(
        intersection_id=intersection_id, intersection_code=code, is_default=is_default,
        phases=[
            PhaseOut(name=p.name, approaches=list(p.approaches), min_green_s=p.min_green_s,
                     max_green_s=p.max_green_s, fixed_green_s=p.fixed_green_s, yellow_s=p.yellow_s,
                     all_red_s=p.all_red_s)
            for p in plan.phases
        ],
        min_cycle_s=plan.min_cycle_s, max_cycle_s=plan.max_cycle_s,
        fixed_cycle_s=plan.fixed_cycle_s, lost_time_s=plan.lost_time_s, updated_at=updated_at,
        approach_bearings={a.name: a.travel_bearing_deg for a in node.approaches} if node is not None else {},
    )


async def load_plans(db: AsyncSession, network: Network, refs: NetworkRefs) -> dict[str, tuple[SignalPlan, bool, datetime | None]]:
    """code -> (plan, is_default, updated_at) for every intersection."""
    configs = {c.intersection_id: c for c in await db.scalars(select(SignalPlanConfig))}
    result = {}
    for code, node in network.intersections.items():
        config = configs.get(refs.by_code[code].id)
        if config is not None:
            result[code] = (plan_from_config(config), False, config.updated_at)
        else:
            result[code] = (default_plan(node), True, None)
    return result


async def get_plan(db: AsyncSession, intersection_id: uuid.UUID) -> SignalPlanOut:
    network, refs = await network_cache.load(db)
    info = refs.by_id.get(intersection_id)
    if info is None:
        raise not_found("Intersection")
    plan, is_default, updated_at = (await load_plans(db, network, refs))[info.code]
    return plan_out(info.id, info.code, plan, is_default, updated_at, network.intersections[info.code])


async def put_plan(db: AsyncSession, actor: User, intersection_id: uuid.UUID, body: SignalPlanIn) -> SignalPlanOut:
    intersection = await db.get(Intersection, intersection_id)
    if intersection is None:
        raise not_found("Intersection")
    network, refs = await network_cache.load(db, use_cache=False)
    node = network.intersections[intersection.code]
    plan = SignalPlan(
        phases=tuple(
            Phase(name=p.name, approaches=tuple(p.approaches), min_green_s=p.min_green_s, max_green_s=p.max_green_s,
                  fixed_green_s=p.fixed_green_s, yellow_s=p.yellow_s, all_red_s=p.all_red_s)
            for p in body.phases
        ),
        min_cycle_s=body.min_cycle_s,
        max_cycle_s=body.max_cycle_s,
    )
    errors = plan.validate()
    known = {a.name for a in node.approaches}
    for p in plan.phases:
        for name in p.approaches:
            if name not in known:
                errors.append(f"{p.name}: approach '{name}' does not exist at {intersection.code}.")
    if errors:
        raise AppError(422, "INVALID_SIGNAL_PLAN", "The signal plan is not valid.",
                       [{"message": e} for e in errors])

    config = await db.get(SignalPlanConfig, intersection.id)
    phases_json = [
        {"name": p.name, "approaches": list(p.approaches), "minGreenS": p.min_green_s, "maxGreenS": p.max_green_s,
         "fixedGreenS": p.fixed_green_s, "yellowS": p.yellow_s, "allRedS": p.all_red_s}
        for p in plan.phases
    ]
    if config is None:
        config = SignalPlanConfig(intersection_id=intersection.id)
        db.add(config)
    config.phases, config.min_cycle_s, config.max_cycle_s = phases_json, plan.min_cycle_s, plan.max_cycle_s
    config.updated_by, config.updated_at = actor.id, utcnow()
    await audit_repo.record(db, "signal.plan_updated", actor_user_id=actor.id, target_type="intersection",
                            target_id=intersection.id, details={"phases": [p.name for p in plan.phases]})
    await db.commit()
    return plan_out(intersection.id, intersection.code, plan, False, config.updated_at, node)


# -- decisions -------------------------------------------------------------------------

def decision_out(record: SignalDecisionRecord, code: str) -> SignalDecisionOut:
    return SignalDecisionOut(
        id=record.id, intersection_code=code, created_at=record.created_at, valid_until=record.valid_until,
        algorithm=record.algorithm, cycle_s=record.cycle_s,
        phase_greens=[PhaseGreenOut(phase=g["phase"], green_s=g["greenS"]) for g in record.phase_greens],
        priority_phase=record.priority_phase, reason=record.reason, inputs=record.inputs,
    )


def engine_decision_out(decision: SignalDecision, record_id: uuid.UUID | None = None) -> SignalDecisionOut:
    return SignalDecisionOut(
        id=record_id, intersection_code=decision.intersection_code, created_at=decision.created_at,
        valid_until=decision.valid_until, algorithm=decision.algorithm.value, cycle_s=decision.cycle_s,
        phase_greens=[PhaseGreenOut(phase=g.phase, green_s=g.green_s) for g in decision.phase_greens],
        priority_phase=decision.priority_phase, reason=decision.reason, inputs=decision.inputs,
    )


@dataclass
class _StoredDecision:
    record_id: uuid.UUID
    decision: SignalDecision


class DecisionStore:
    """Keeps the latest decision per intersection and writes a row only when it changes.

    While a decision stays materially the same, its validity is extended in place, so the
    table records decision changes rather than one row per engine cycle.
    """

    def __init__(self) -> None:
        self.latest: dict[str, _StoredDecision] = {}

    async def store(self, db: AsyncSession, decisions: dict[str, SignalDecision], refs: NetworkRefs) -> None:
        for code, decision in decisions.items():
            info = refs.by_code.get(code)
            if info is None:
                continue
            current = self.latest.get(code)
            if current is not None and not decision.materially_differs(current.decision):
                record = await db.get(SignalDecisionRecord, current.record_id)
                if record is not None:
                    record.valid_until = decision.valid_until
                    record.reason, record.inputs = decision.reason, decision.inputs
                    current.decision = decision
                    continue
            record = SignalDecisionRecord(
                intersection_id=info.id, created_at=decision.created_at, valid_until=decision.valid_until,
                algorithm=decision.algorithm.value, cycle_s=decision.cycle_s,
                phase_greens=[{"phase": g.phase, "greenS": g.green_s} for g in decision.phase_greens],
                priority_phase=decision.priority_phase, reason=decision.reason, inputs=decision.inputs,
            )
            db.add(record)
            await db.flush()
            self.latest[code] = _StoredDecision(record.id, decision)
        for code in list(self.latest):
            if code not in decisions:
                del self.latest[code]  # intersection switched to FIXED or became inactive

    def current(self, code: str, now: datetime) -> _StoredDecision | None:
        stored = self.latest.get(code)
        if stored is None or stored.decision.valid_until <= now:
            return None
        return stored

    def reset(self) -> None:
        self.latest.clear()


decision_store = DecisionStore()


async def recent_decisions(db: AsyncSession, intersection_id: uuid.UUID, limit: int) -> list[SignalDecisionOut]:
    intersection = await db.get(Intersection, intersection_id)
    if intersection is None:
        raise not_found("Intersection")
    rows = await db.scalars(
        select(SignalDecisionRecord)
        .where(SignalDecisionRecord.intersection_id == intersection.id)
        .order_by(SignalDecisionRecord.created_at.desc())
        .limit(limit)
    )
    return [decision_out(r, intersection.code) for r in rows]


async def latest_valid_decision(db: AsyncSession, intersection_id: uuid.UUID, code: str, now: datetime) -> SignalDecisionOut | None:
    stored = decision_store.current(code, now)
    if stored is not None:
        return engine_decision_out(stored.decision, stored.record_id)
    record = await db.scalar(
        select(SignalDecisionRecord)
        .where(SignalDecisionRecord.intersection_id == intersection_id, SignalDecisionRecord.valid_until > now)
        .order_by(SignalDecisionRecord.created_at.desc())
        .limit(1)
    )
    return decision_out(record, code) if record else None


# -- reported signal states --------------------------------------------------------------

@dataclass
class _LatestState:
    out: SignalStateOut
    stored_at: datetime


class SignalStateStore:
    """Latest reported state per intersection (memory) + change/heartbeat rows (database)."""

    def __init__(self) -> None:
        self.latest: dict[str, _LatestState] = {}

    async def record(
        self, db: AsyncSession, intersection_id: uuid.UUID, code: str, report: SignalStateReport,
        *, client_id: uuid.UUID | None, source: str, now: datetime,
    ) -> None:
        reported_at = report.reported_at or now
        out = SignalStateOut(phase_name=report.phase_name, state=report.state, remaining_s=report.remaining_s,
                             mode=report.mode, reported_at=reported_at, source=source)
        previous = self.latest.get(code)
        changed = previous is None or (previous.out.phase_name, previous.out.state, previous.out.mode) != (
            out.phase_name, out.state, out.mode
        )
        stored_at = previous.stored_at if previous else now
        if changed or (now - stored_at).total_seconds() >= STATE_HEARTBEAT_S:
            db.add(SignalStateRecord(
                intersection_id=intersection_id, reported_at=reported_at, received_at=now,
                phase_name=out.phase_name, state=out.state, remaining_s=out.remaining_s, mode=out.mode,
                decision_id=report.decision_id, client_id=client_id, source=source,
            ))
            stored_at = now
        self.latest[code] = _LatestState(out, stored_at)

    def get(self, code: str) -> SignalStateOut | None:
        state = self.latest.get(code)
        return state.out if state else None

    def connected(self, code: str, now: datetime) -> bool:
        state = self.latest.get(code)
        return state is not None and (now - state.out.reported_at) <= timedelta(seconds=CONNECTED_WITHIN_S)

    def reset(self) -> None:
        self.latest.clear()


state_store = SignalStateStore()


async def latest_state(db: AsyncSession, intersection_id: uuid.UUID, code: str) -> SignalStateOut | None:
    state = state_store.get(code)
    if state is not None:
        return state
    record = await db.scalar(
        select(SignalStateRecord)
        .where(SignalStateRecord.intersection_id == intersection_id)
        .order_by(SignalStateRecord.reported_at.desc())
        .limit(1)
    )
    if record is None:
        return None
    return SignalStateOut(phase_name=record.phase_name, state=record.state, remaining_s=record.remaining_s,
                          mode=record.mode, reported_at=record.reported_at, source=record.source)


# -- control modes -----------------------------------------------------------------------

def control_config() -> ControlConfigOut:
    th = get_settings().mode_thresholds()
    window = f"{th.window_s:.0f} s"
    return ControlConfigOut(
        enter_level=th.enter_level.value, exit_level=th.exit_level.value, window_s=th.window_s,
        enter_hold_s=th.enter_hold_s, exit_hold_s=th.exit_hold_s, min_adaptive_s=th.min_adaptive_s,
        min_data_quality=th.min_data_quality.value, min_vehicles=th.min_vehicles,
        rules=[
            f"Congestion is averaged over the last {window}, so normal queues at a red light do not count.",
            f"Fixed-time -> adaptive: average congestion {th.enter_level.value} or worse with at least "
            f"{th.min_vehicles:.0f} vehicles for {th.enter_hold_s:.0f} s.",
            f"Adaptive -> fixed-time: average congestion {th.exit_level.value} (or fewer than "
            f"{th.min_vehicles:.0f} vehicles) for {th.exit_hold_s:.0f} s, after at least "
            f"{th.min_adaptive_s:.0f} s in adaptive mode.",
            f"Not enough data (quality below {th.min_data_quality.value}): fixed-time, the safe default.",
            "An emergency vehicle about to arrive gets priority in either mode.",
            "Timings are advisory: the signal controller keeps minimum green, yellow and all-red times.",
        ],
    )


async def mode_events(db: AsyncSession, intersection_id: uuid.UUID | None, limit: int) -> list[ModeEventOut]:
    _, refs = await network_cache.load(db)
    stmt = select(SignalModeEvent).order_by(SignalModeEvent.at.desc(), SignalModeEvent.id.desc()).limit(limit)
    if intersection_id is not None:
        if intersection_id not in refs.by_id:
            raise not_found("Intersection")
        stmt = stmt.where(SignalModeEvent.intersection_id == intersection_id)
    result = []
    for row in await db.scalars(stmt):
        info = refs.by_id.get(row.intersection_id)
        try:
            traffic = TrafficBasisOut.model_validate(row.traffic) if row.traffic else None
        except ValueError:
            traffic = None
        result.append(ModeEventOut(
            id=row.id, intersection_id=row.intersection_id, intersection_code=info.code if info else "?",
            at=row.at, policy=row.policy, from_mode=row.from_mode, to_mode=row.to_mode, reason=row.reason,
            headline=row.headline, detail=row.detail, traffic=traffic,
        ))
    return result
