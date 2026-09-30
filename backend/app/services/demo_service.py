"""Demo mode: a simulated fleet driving the configured network (DEMO_MODE=true only).

Simulated vehicles are real `vehicles` rows (is_simulated, SIM- codes) owned by a disabled
system account. Their telemetry goes through the same validation and ingest code as phones,
tagged SIMULATOR. Virtual signals execute the engine's decisions, so adaptive control has a
visible effect.
"""
import asyncio
import logging
import secrets
import time
import uuid
from datetime import datetime

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker
from traffic_engine.control import SignalDecision, SignalPlan
from traffic_engine.simulation import DemoFleet, VehicleSpec, VirtualSignal

from app.core.config import get_settings
from app.core.errors import AppError
from app.core.security import hash_password
from app.core.time import utcnow
from app.models.emergency import EmergencyEvent
from app.models.enums import (
    AuthorizationStatus,
    EmergencyEndReason,
    EmergencyEventStatus,
    LightState,
    SessionEndReason,
    SignalMode,
    TelemetrySource,
    UserRole,
    VehicleStatus,
    VehicleType,
)
from app.models.telemetry import TrackingSession
from app.models.user import User
from app.models.vehicle import EmergencyAuthorization, Vehicle
from app.repositories import audit_repo, vehicle_repo
from app.schemas.demo import DemoStatusOut
from app.schemas.signals import SignalStateReport
from app.schemas.telemetry import TelemetryInput
from app.services import emergency_service, network_cache, signal_service, telemetry_service

logger = logging.getLogger("app.demo")

SIM_OWNER_EMAIL = "simulator@demo.invalid"  # .invalid is a reserved TLD: can never receive mail
TICK_S = 1.0
SUBSTEPS = 2


class DemoService:
    def __init__(self) -> None:
        self.fleet: DemoFleet | None = None
        self.signals: dict[str, VirtualSignal] = {}
        self.started_at: datetime | None = None
        self._task: asyncio.Task | None = None
        self._vehicle_ids: dict[str, uuid.UUID] = {}
        self._sessions: dict[str, uuid.UUID] = {}
        self._seq: dict[str, int] = {}
        self._emergency_keys: set[str] = set()
        self._stopping = False

    @property
    def running(self) -> bool:
        return self.fleet is not None

    def fully_observed_codes(self) -> set[str]:
        if self.fleet is None:
            return set()
        return {n.code for n in self.fleet.network.active()}

    def apply_decisions(self, decisions: dict[str, SignalDecision], plans: dict[str, SignalPlan]) -> None:
        for code, signal in self.signals.items():
            if code in plans:
                signal.set_plan(plans[code])
            signal.apply(decisions.get(code))  # FIXED intersections get None: local plan runs

    def status(self) -> DemoStatusOut:
        fleet = self.fleet
        return DemoStatusOut(
            enabled=get_settings().demo_mode,
            running=fleet is not None,
            started_at=self.started_at,
            vehicles=len(fleet.vehicles) if fleet else 0,
            active_vehicles=fleet.active_count if fleet else 0,
            emergency_active=bool(self._emergency_keys),
            simulated_seconds=round(fleet.clock_s, 1) if fleet else 0.0,
        )

    # -- lifecycle ---------------------------------------------------------------------
    async def start(
        self, factory: async_sessionmaker, actor: User, vehicles: int, include_emergency: bool, seed: int | None,
        *, run_loop: bool = True,
    ) -> DemoStatusOut:
        settings = get_settings()
        if not settings.demo_mode:
            raise AppError(403, "DEMO_DISABLED", "Demo mode is disabled on this server (DEMO_MODE=false).")
        if vehicles > settings.demo_max_vehicles:
            raise AppError(422, "TOO_MANY_VEHICLES", f"At most {settings.demo_max_vehicles} simulated vehicles.")
        if self.running:
            raise AppError(409, "DEMO_RUNNING", "The simulation is already running.")

        async with factory() as db:
            network, refs = await network_cache.load(db, use_cache=False)
            if not network.active():
                raise AppError(409, "NO_INTERSECTIONS", "Create at least one active intersection first.")
            owner = await self._sim_owner(db)
            normal = await self._sim_vehicles(db, owner, VehicleType.NORMAL, vehicles)
            specs = [VehicleSpec(f"veh:{v.id}", v.code, v.vehicle_type.value) for v in normal]
            ids = {f"veh:{v.id}": v.id for v in normal}
            if include_emergency:
                ambulance = (await self._sim_vehicles(db, owner, VehicleType.AMBULANCE, 1))[0]
                await self._ensure_authorized(db, ambulance, actor)
                specs.append(VehicleSpec(f"veh:{ambulance.id}", ambulance.code, ambulance.vehicle_type.value))
                ids[f"veh:{ambulance.id}"] = ambulance.id
            plans = await signal_service.load_plans(db, network, refs)
            await audit_repo.record(db, "demo.started", actor_user_id=actor.id, details={"vehicles": vehicles})
            await db.commit()

        self.fleet = DemoFleet(network, specs, seed=seed if seed is not None else secrets.randbelow(10_000))
        self.signals = {code: VirtualSignal(code, plans[code][0]) for code in network.intersections}
        self._vehicle_ids = ids
        self._sessions, self._seq, self._emergency_keys = {}, {}, set()
        self.started_at = utcnow()
        if run_loop:
            self._task = asyncio.create_task(self._loop(factory), name="demo-fleet")
        return self.status()

    async def stop(self, factory: async_sessionmaker, actor: User | None) -> DemoStatusOut:
        if self._task is not None:
            # Let the current tick finish its transaction instead of cancelling it midway.
            self._stopping = True
            try:
                await asyncio.wait_for(asyncio.shield(self._task), timeout=5.0)
            except (asyncio.TimeoutError, asyncio.CancelledError):
                self._task.cancel()
                try:
                    await self._task
                except asyncio.CancelledError:
                    pass
            self._task = None
            self._stopping = False
        async with factory() as db:
            await self._close_all(db, utcnow())
            if actor is not None:
                await audit_repo.record(db, "demo.stopped", actor_user_id=actor.id)
            await db.commit()
        self.fleet, self.signals, self.started_at = None, {}, None
        self._sessions, self._seq, self._emergency_keys, self._vehicle_ids = {}, {}, set(), {}
        return self.status()

    async def _close_all(self, db: AsyncSession, now: datetime) -> None:
        sim_ids = list(self._vehicle_ids.values())
        if not sim_ids:
            return
        for session in await db.scalars(
            select(TrackingSession).where(TrackingSession.vehicle_id.in_(sim_ids), TrackingSession.ended_at.is_(None))
        ):
            session.ended_at, session.end_reason = now, SessionEndReason.DEMO_STOPPED
        for event in await db.scalars(
            select(EmergencyEvent).where(
                EmergencyEvent.vehicle_id.in_(sim_ids), EmergencyEvent.status == EmergencyEventStatus.ACTIVE
            )
        ):
            await emergency_service.end_active_for_vehicle(db, event.vehicle_id, EmergencyEndReason.DEMO_STOPPED, now)

    # -- provisioning ------------------------------------------------------------------
    async def _sim_owner(self, db: AsyncSession) -> User:
        owner = await db.scalar(select(User).where(User.email == SIM_OWNER_EMAIL))
        if owner is None:
            owner = User(
                email=SIM_OWNER_EMAIL, full_name="Demo simulator (system)", role=UserRole.END_USER,
                is_active=False,  # nobody can log in as the simulator
                password_hash=await asyncio.to_thread(hash_password, secrets.token_urlsafe(32)),
            )
            db.add(owner)
            await db.flush()
        return owner

    async def _sim_vehicles(self, db: AsyncSession, owner: User, vehicle_type: VehicleType, n: int) -> list[Vehicle]:
        existing = list(await db.scalars(
            select(Vehicle)
            .where(Vehicle.owner_user_id == owner.id, Vehicle.is_simulated.is_(True), Vehicle.vehicle_type == vehicle_type)
            .order_by(Vehicle.code)
        ))
        while len(existing) < n:
            code = await vehicle_repo.allocate_code(db, "SIM")
            vehicle = Vehicle(
                code=code, owner_user_id=owner.id, vehicle_type=vehicle_type, is_simulated=True,
                display_name=f"Simulated {vehicle_type.value.lower().replace('_', ' ')}",
                registration_number=code if vehicle_type.is_emergency else None,
            )
            db.add(vehicle)
            await db.flush()
            existing.append(vehicle)
        chosen = existing[:n]
        for v in chosen:
            v.status = VehicleStatus.ACTIVE
        return chosen

    async def _ensure_authorized(self, db: AsyncSession, vehicle: Vehicle, actor: User) -> None:
        now = utcnow()
        auth = await emergency_service.latest_authorization(db, vehicle.id)
        if auth is not None and auth.status == AuthorizationStatus.APPROVED and (
            auth.valid_until is None or auth.valid_until > now
        ):
            return
        db.add(EmergencyAuthorization(
            vehicle_id=vehicle.id, status=AuthorizationStatus.APPROVED, requested_by=actor.id,
            reviewed_by=actor.id, reviewed_at=now, created_at=now, notes="Simulated vehicle (demo mode).",
        ))
        await db.flush()

    # -- simulation loop -----------------------------------------------------------------
    async def _loop(self, factory: async_sessionmaker) -> None:
        while not self._stopping:
            started = time.monotonic()
            try:
                await self.tick(factory)
            except asyncio.CancelledError:
                raise
            except Exception:
                logger.exception("Demo simulation tick failed")
            deadline = time.monotonic() + max(0.05, TICK_S - (time.monotonic() - started))
            while not self._stopping and time.monotonic() < deadline:
                await asyncio.sleep(0.05)

    async def tick(self, factory: async_sessionmaker, now: datetime | None = None) -> None:
        fleet = self.fleet
        if fleet is None:
            return
        now = now or utcnow()
        for _ in range(SUBSTEPS):
            fleet.step(TICK_S / SUBSTEPS, now, self.signals)
            for signal in self.signals.values():
                signal.step(TICK_S / SUBSTEPS, now)

        async with factory() as db:
            network, refs = await network_cache.load(db)
            vehicles = {
                v.id: v for v in await db.scalars(select(Vehicle).where(Vehicle.id.in_(list(self._vehicle_ids.values()))))
            }
            for event in fleet.drain_events():
                await self._handle_event(db, event.kind, event.vehicle_key, vehicles, now)

            for obs in fleet.observations(now):
                vehicle = vehicles.get(self._vehicle_ids.get(obs.key))
                session_id = self._sessions.get(obs.key)
                if vehicle is None or session_id is None:
                    continue
                session = await db.get(TrackingSession, session_id)
                seq = self._seq.get(obs.key, 0)
                self._seq[obs.key] = seq + 1
                packet = TelemetryInput(
                    seq=seq, recorded_at=obs.recorded_at, lat=obs.lat, lon=obs.lon, accuracy_m=obs.accuracy_m,
                    speed_mps=obs.speed_mps, heading_deg=obs.heading_deg, emergency=obs.emergency, mocked=False,
                )
                await telemetry_service.ingest(
                    db, vehicle=vehicle, session=session, packets=[packet], source=TelemetrySource.SIMULATOR,
                    emergency_active=obs.key in self._emergency_keys, now=now, network=network, refs=refs,
                )

            for code, signal in self.signals.items():
                info = refs.by_code.get(code)
                if info is None:
                    continue
                mode = signal.mode(now)
                await signal_service.state_store.record(
                    db, info.id, code,
                    SignalStateReport(
                        intersection_code=code, phase_name=signal.phase.name, state=LightState(signal.state.value),
                        mode=SignalMode(mode.value), remaining_s=round(signal.remaining_s(now), 1), reported_at=now,
                    ),
                    client_id=None, source="SIMULATOR", now=now,
                )
            await db.commit()

    async def _handle_event(self, db: AsyncSession, kind: str, key: str, vehicles: dict, now: datetime) -> None:
        vehicle = vehicles.get(self._vehicle_ids.get(key))
        if vehicle is None:
            return
        if kind == "TRIP_STARTED":
            session = TrackingSession(vehicle_id=vehicle.id, source=TelemetrySource.SIMULATOR, started_at=now)
            db.add(session)
            await db.flush()
            self._sessions[key], self._seq[key] = session.id, 0
        elif kind == "TRIP_ENDED":
            session_id = self._sessions.pop(key, None)
            session = await db.get(TrackingSession, session_id) if session_id else None
            if session is not None and session.ended_at is None:
                session.ended_at, session.end_reason = now, SessionEndReason.USER
        elif kind == "EMERGENCY_STARTED":
            await emergency_service.start_simulated(db, vehicle, self._sessions.get(key), now)
            if await emergency_service.active_event(db, vehicle.id) is not None:
                self._emergency_keys.add(key)
        elif kind == "EMERGENCY_ENDED":
            self._emergency_keys.discard(key)
            await emergency_service.end_active_for_vehicle(db, vehicle.id, EmergencyEndReason.DRIVER, now)


demo = DemoService()
