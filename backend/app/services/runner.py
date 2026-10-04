"""The periodic engine cycle: observations → traffic_engine → decisions, history, broadcast.

Runs as one asyncio task inside the API process (single-process deployment, ADR 0002).
Tests call run_cycle() directly instead of starting the loop.
"""
import asyncio
import logging
import time
from dataclasses import dataclass, field
from datetime import datetime, timedelta

from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker
from traffic_engine import Network, NetworkState, Observation, Source, TrafficEngine
from traffic_engine.control import ControlPolicy, ControlStatus, ModeChange, SignalDecision, SignalPlan
from traffic_engine.simulation import VirtualSignal

from app.core.config import get_settings
from app.core.time import utcnow
from app.models.enums import IntersectionStatus, LightState, SignalMode, TelemetrySource, VehicleStatus
from app.models.telemetry import VehicleLiveState, VehicleTelemetry
from app.models.traffic import SignalDecisionRecord, SignalModeEvent, SignalStateRecord, TrafficMetric
from app.models.vehicle import Vehicle
from app.realtime.hub import hub, queue_event
from app.schemas.traffic import SignalStateOut
from app.services import emergency_service, network_cache, signal_service, tracking_service
from app.services.demo_service import demo
from app.services.external_sources import external_store
from app.services.network_cache import NetworkRefs

logger = logging.getLogger("app.runner")

HOUSEKEEPING_INTERVAL_S = 10.0
RETENTION_INTERVAL_S = 3600.0
MODE_EVENT_RETENTION_DAYS = 90
VIRTUAL_STEP_S = 0.5
VIRTUAL_MAX_GAP_S = 10.0


@dataclass
class CycleSnapshot:
    computed_at: datetime
    cycle_ms: float
    network: Network
    refs: NetworkRefs
    state: NetworkState
    decisions: dict[str, SignalDecision]
    plans: dict[str, tuple[SignalPlan, bool, datetime | None]]
    observation_count: int
    control: dict[str, ControlStatus] = field(default_factory=dict)


async def vehicle_observations(db: AsyncSession, now: datetime) -> list[Observation]:
    """Fresh, usable live states of active registered vehicles (phones and the demo fleet)."""
    window = get_settings().live_window_s
    rows = (
        await db.execute(
            select(VehicleLiveState, Vehicle)
            .join(Vehicle, Vehicle.id == VehicleLiveState.vehicle_id)
            .where(
                VehicleLiveState.recorded_at >= now - timedelta(seconds=window),
                VehicleLiveState.usable.is_(True),
                Vehicle.status == VehicleStatus.ACTIVE,
            )
        )
    ).all()
    return [
        Observation(
            key=f"veh:{vehicle.id}", source=Source(live.source.value), lat=live.lat, lon=live.lon,
            recorded_at=live.recorded_at, accuracy_m=live.accuracy_m, speed_mps=live.speed_mps,
            heading_deg=live.heading_deg, emergency=live.emergency, vehicle_type=vehicle.vehicle_type.value,
            label=vehicle.code,
        )
        for live, vehicle in rows
    ]


class TrafficRunner:
    def __init__(self) -> None:
        self.engine = TrafficEngine(thresholds=get_settings().mode_thresholds())
        self.latest: CycleSnapshot | None = None
        # Virtual controllers that run each intersection's plan and decisions, so the lights can
        # be shown where no actuator (demo, SUMO, hardware) reports a real signal state.
        self.virtual: dict[str, VirtualSignal] = {}
        self._virtual_at: datetime | None = None
        self._task: asyncio.Task | None = None
        self._last_persist: datetime | None = None
        self._last_housekeeping: datetime | None = None
        self._last_retention: datetime | None = None
        self._lock = asyncio.Lock()

    @property
    def running(self) -> bool:
        return self._task is not None and not self._task.done()

    def start(self, factory: async_sessionmaker) -> None:
        if not self.running:
            self._task = asyncio.create_task(self._loop(factory), name="traffic-runner")

    async def stop(self) -> None:
        if self._task is not None:
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass
            self._task = None

    async def _loop(self, factory: async_sessionmaker) -> None:
        interval = get_settings().traffic_cycle_s
        while True:
            started = time.monotonic()
            try:
                await self.run_cycle(factory)
            except asyncio.CancelledError:
                raise
            except Exception:
                logger.exception("Traffic engine cycle failed")
            await asyncio.sleep(max(0.1, interval - (time.monotonic() - started)))

    def _due(self, last: datetime | None, now: datetime, interval_s: float) -> bool:
        return last is None or (now - last).total_seconds() >= interval_s

    async def run_cycle(
        self, factory: async_sessionmaker, *, now: datetime | None = None, persist: bool = True, broadcast: bool = True
    ) -> CycleSnapshot:
        async with self._lock:
            return await self._run_cycle(factory, now or utcnow(), persist, broadcast)

    async def _run_cycle(self, factory, now: datetime, persist: bool, broadcast: bool) -> CycleSnapshot:
        from app.services import live_service

        settings = get_settings()
        t0 = time.perf_counter()
        message = None
        async with factory() as db:
            network, refs = await network_cache.load(db)
            observations = await vehicle_observations(db, now) + external_store.observations(now)
            plans = await signal_service.load_plans(db, network, refs)
            policies = {
                code: ControlPolicy(info.controller_type.value)
                for code, info in refs.by_code.items() if info.status == IntersectionStatus.ACTIVE
            }
            result = self.engine.run_cycle(
                network, observations, now,
                plans={code: p[0] for code, p in plans.items()},
                policies=policies,
                detector_counts=external_store.counts(now),
                fully_observed_codes=external_store.fully_observed_codes(now) | demo.fully_observed_codes(),
            )
            snapshot = CycleSnapshot(
                computed_at=now, cycle_ms=0.0, network=network, refs=refs, state=result.state,
                decisions=result.decisions, plans=plans, observation_count=len(observations),
                control=result.control,
            )
            self._step_virtual(plans, result.decisions, set(policies), now)
            if persist:
                await signal_service.decision_store.store(db, result.decisions, refs)
                record_mode_changes(db, result.mode_changes, result.control, refs)
                if self._due(self._last_persist, now, settings.metrics_persist_interval_s):
                    await persist_metrics(db, result.state, refs, now)
                    self._last_persist = now
                if self._due(self._last_housekeeping, now, HOUSEKEEPING_INTERVAL_S):
                    await emergency_service.expire(db, now)
                    await tracking_service.close_idle(db, now)
                    self._last_housekeeping = now
                if self._due(self._last_retention, now, RETENTION_INTERVAL_S):
                    await apply_retention(db, now)
                    self._last_retention = now
                await db.commit()
            snapshot.cycle_ms = round((time.perf_counter() - t0) * 1000.0, 1)
            self.latest = snapshot
            if broadcast and hub.client_count:
                message = await live_service.snapshot_message(db, snapshot, now)

        demo.apply_decisions(result.decisions, {code: p[0] for code, p in plans.items()})
        if message is not None:
            await hub.publish_snapshot(message)
        return snapshot

    async def current(self, factory: async_sessionmaker, now: datetime | None = None) -> CycleSnapshot:
        """The latest cycle if recent; otherwise compute one now without side effects."""
        now = now or utcnow()
        max_age = 3 * get_settings().traffic_cycle_s
        if self.latest is not None and (now - self.latest.computed_at).total_seconds() <= max_age:
            return self.latest
        return await self.run_cycle(factory, now=now, persist=False, broadcast=False)

    # -- virtual signals ---------------------------------------------------------------
    def _step_virtual(self, plans, decisions: dict[str, SignalDecision], codes: set[str], now: datetime) -> None:
        last, self._virtual_at = self._virtual_at, now
        dt = 0.0 if last is None else max(0.0, min(VIRTUAL_MAX_GAP_S, (now - last).total_seconds()))
        for code in list(self.virtual):
            if code not in codes:
                del self.virtual[code]
        for code in codes:
            plan = plans[code][0]
            signal = self.virtual.get(code)
            if signal is None:
                signal = self.virtual[code] = VirtualSignal(code, plan)
            else:
                signal.set_plan(plan)
            signal.apply(decisions.get(code))
            elapsed = 0.0
            while elapsed < dt - 1e-9:
                step = min(VIRTUAL_STEP_S, dt - elapsed)
                signal.step(step, now)
                elapsed += step

    def virtual_state(self, code: str) -> SignalStateOut | None:
        signal = self.virtual.get(code)
        if signal is None or self._virtual_at is None:
            return None
        at = self._virtual_at
        return SignalStateOut(
            phase_name=signal.phase.name, state=LightState(signal.state.value),
            remaining_s=round(signal.remaining_s(at), 1), mode=SignalMode(signal.mode(at).value),
            reported_at=at, source="VIRTUAL",
        )

    def reset(self) -> None:
        self.engine = TrafficEngine(thresholds=get_settings().mode_thresholds())
        self.latest = None
        self.virtual, self._virtual_at = {}, None
        self._last_persist = self._last_housekeeping = self._last_retention = None


async def persist_metrics(db: AsyncSession, state: NetworkState, refs: NetworkRefs, now: datetime) -> None:
    for code, s in state.intersections.items():
        info = refs.by_code.get(code)
        if info is None:
            continue
        m = s.metrics
        db.add(TrafficMetric(
            intersection_id=info.id, approach_id=None, window_end=now,
            observed_vehicle_count=m.observed.vehicle_count, observed_stopped_count=m.observed.stopped_count,
            observed_emergency_count=m.observed.emergency_count, observed_avg_speed_mps=m.observed.avg_speed_mps,
            observed_min_speed_mps=m.observed.min_speed_mps, observed_max_speed_mps=m.observed.max_speed_mps,
            calc_speed_ratio=m.speed_ratio, calc_avg_waiting_time_s=m.avg_waiting_time_s,
            calc_expected_arrivals_60s=sum(a.expected_arrivals_60s for a in m.approaches),
            est_vehicle_count=m.estimated_vehicle_count, est_density_veh_per_km_lane=m.density_veh_per_km_lane,
            congestion_level=m.congestion_level.value, data_quality=m.data_quality.value, sources=m.sources,
        ))
        for a in m.approaches:
            approach_id = refs.approach_ids.get((code, a.approach_name))
            if approach_id is None:
                continue
            db.add(TrafficMetric(
                intersection_id=info.id, approach_id=approach_id, window_end=now,
                observed_vehicle_count=a.observed.vehicle_count, observed_stopped_count=a.observed.stopped_count,
                observed_emergency_count=a.observed.emergency_count, observed_avg_speed_mps=a.observed.avg_speed_mps,
                observed_min_speed_mps=a.observed.min_speed_mps, observed_max_speed_mps=a.observed.max_speed_mps,
                calc_speed_ratio=a.speed_ratio, calc_avg_waiting_time_s=a.avg_waiting_time_s,
                calc_expected_arrivals_60s=a.expected_arrivals_60s,
                est_vehicle_count=a.estimated_vehicle_count, est_density_veh_per_km_lane=a.density_veh_per_km_lane,
                congestion_level=a.congestion_level.value, data_quality=a.data_quality.value, sources=m.sources,
            ))


def record_mode_changes(
    db: AsyncSession, changes: list[ModeChange], control: dict[str, ControlStatus], refs: NetworkRefs
) -> None:
    """Log each mode change and tell connected dashboards once the transaction commits."""
    from app.services import traffic_views

    for change in changes:
        info = refs.by_code.get(change.code)
        if info is None:
            continue
        traffic = traffic_views.basis_out(change.traffic).model_dump(mode="json", by_alias=True)
        policy = control[change.code].policy.value if change.code in control else ""
        db.add(SignalModeEvent(
            intersection_id=info.id, at=change.at, policy=policy, from_mode=change.from_mode.value,
            to_mode=change.to_mode.value, reason=change.reason.value, headline=change.headline[:120],
            detail=change.detail, traffic=traffic,
        ))
        queue_event(
            db, "MODE_CHANGED", intersectionId=str(info.id), intersectionCode=change.code,
            fromMode=change.from_mode.value, toMode=change.to_mode.value, reason=change.reason.value,
            headline=change.headline, detail=change.detail,
        )


async def apply_retention(db: AsyncSession, now: datetime) -> None:
    """Delete raw data past its retention period (see docs/SECURITY_AND_PRIVACY.md)."""
    s = get_settings()
    await db.execute(delete(VehicleTelemetry).where(
        VehicleTelemetry.source == TelemetrySource.MOBILE,
        VehicleTelemetry.received_at < now - timedelta(days=s.telemetry_retention_days),
    ))
    await db.execute(delete(VehicleTelemetry).where(
        VehicleTelemetry.source == TelemetrySource.SIMULATOR,
        VehicleTelemetry.received_at < now - timedelta(hours=s.simulated_telemetry_retention_hours),
    ))
    await db.execute(delete(SignalStateRecord).where(SignalStateRecord.received_at < now - timedelta(days=30)))
    await db.execute(delete(SignalDecisionRecord).where(SignalDecisionRecord.valid_until < now - timedelta(days=90)))
    await db.execute(delete(TrafficMetric).where(TrafficMetric.window_end < now - timedelta(days=365)))
    await db.execute(delete(SignalModeEvent).where(SignalModeEvent.at < now - timedelta(days=MODE_EVENT_RETENTION_DAYS)))


runner = TrafficRunner()
