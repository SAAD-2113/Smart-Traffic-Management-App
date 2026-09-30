"""SUMO <-> Smart Traffic backend bridge (TraCI).

Every simulated second:
  1. reads all SUMO vehicles (position converted to lon/lat, speed, heading, emergency class)
     and posts them to /controller/observations (source SUMO);
  2. every 2 s fetches /controller/decisions (advisory timing + the plan of each intersection);
  3. drives each SUMO traffic light with the same safety-respecting VirtualSignal the demo uses:
     a decision is applied only while valid, and minimum green, yellow and all-red times are kept;
     without a valid decision the light runs its fixed plan;
  4. reports the actual light states to /controller/signal-states.

The backend treats SUMO vehicles as observations, never as registered vehicles.

Usage:
    uv run python bridge.py --backend http://localhost:8000 --key stc_... [--gui]
The key comes from POST /api/v1/admin/controller-clients (kind SUMO_BRIDGE, scoped to I1..I4);
it can also be given as the SMART_TRAFFIC_CONTROLLER_KEY environment variable.
"""
import argparse
import logging
import math
import os
import time
from datetime import datetime, timezone
from pathlib import Path

import httpx
import traci
from traffic_engine.control import Algorithm, Phase, PhaseGreen, SignalDecision, SignalPlan
from traffic_engine.geo import angle_diff_deg
from traffic_engine.simulation import LightState, VirtualSignal

log = logging.getLogger("sumo_bridge")
HERE = Path(__file__).parent


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def sumo_binary(gui: bool) -> str:
    name = "sumo-gui" if gui else "sumo"
    try:
        import sumo  # eclipse-sumo wheel

        return str(Path(sumo.SUMO_HOME) / "bin" / name)
    except ImportError:
        home = os.environ.get("SUMO_HOME")
        return str(Path(home) / "bin" / name) if home else name


def lane_bearing(lane_id: str) -> float:
    """Direction of travel at the end of a lane, as a compass bearing (0 = north)."""
    (x1, y1), (x2, y2) = traci.lane.getShape(lane_id)[-2:]
    return (90.0 - math.degrees(math.atan2(y2 - y1, x2 - x1))) % 360.0


def parse_plan(data: dict) -> SignalPlan:
    return SignalPlan(
        phases=tuple(
            Phase(p["name"], tuple(p["approaches"]), p["minGreenS"], p["maxGreenS"], p["fixedGreenS"], p["yellowS"],
                  p["allRedS"])
            for p in data["phases"]
        ),
        min_cycle_s=data["minCycleS"],
        max_cycle_s=data["maxCycleS"],
    )


def parse_decision(data: dict) -> SignalDecision:
    return SignalDecision(
        intersection_code=data["intersectionCode"],
        created_at=datetime.fromisoformat(data["createdAt"]),
        valid_until=datetime.fromisoformat(data["validUntil"]),
        algorithm=Algorithm(data["algorithm"]),
        cycle_s=data["cycleS"],
        phase_greens=tuple(PhaseGreen(g["phase"], g["greenS"]) for g in data["phaseGreens"]),
        reason=data["reason"],
        priority_phase=data.get("priorityPhase"),
    )


class TrafficLight:
    """One SUMO traffic light driven by a VirtualSignal."""

    def __init__(self, code: str, tls_id: str) -> None:
        self.code = code
        self.tls_id = tls_id
        links = traci.trafficlight.getControlledLinks(tls_id)
        self.link_bearings = [lane_bearing(group[0][0]) if group else None for group in links]
        self.link_phase: list[str | None] = [None] * len(links)
        # Keep SUMO's right-of-way on green: a movement that must yield in the network's own
        # program (lower-case 'g', e.g. a permissive left turn) keeps yielding here.
        default = traci.trafficlight.getAllProgramLogics(tls_id)[0].phases
        self.link_green = ["g" if any(p.state[i] == "g" for p in default) else "G" for i in range(len(links))]
        self.signal: VirtualSignal | None = None
        self.decision_id: str | None = None

    def set_plan(self, plan_data: dict) -> None:
        plan = parse_plan(plan_data)
        bearings: dict[str, float] = plan_data.get("approachBearings", {})
        for i, bearing in enumerate(self.link_bearings):
            best, best_diff = None, 46.0
            for name, approach_bearing in bearings.items():
                diff = angle_diff_deg(bearing, approach_bearing) if bearing is not None else 999
                if diff < best_diff:
                    best, best_diff = name, diff
            phase = plan.phase_for_approach(best)
            self.link_phase[i] = phase.name if phase else None
        if self.signal is None:
            self.signal = VirtualSignal(self.code, plan)
        else:
            self.signal.set_plan(plan)

    def apply(self, decision: dict | None) -> None:
        if self.signal is None:
            return
        self.signal.apply(parse_decision(decision) if decision else None)
        self.decision_id = decision.get("id") if decision else None

    def step(self, dt: float, now: datetime) -> None:
        if self.signal is None:
            return
        self.signal.step(dt, now)
        current, light = self.signal.phase.name, self.signal.state
        state = "".join(
            (green if light == LightState.GREEN else "y" if light == LightState.YELLOW else "r")
            if phase == current else "r"
            for phase, green in zip(self.link_phase, self.link_green)
        )
        traci.trafficlight.setRedYellowGreenState(self.tls_id, state)

    def report(self, now: datetime) -> dict | None:
        if self.signal is None:
            return None
        return {
            "intersectionCode": self.code,
            "phaseName": self.signal.phase.name,
            "state": self.signal.state.value,
            "mode": self.signal.mode(now).value,
            "remainingS": round(self.signal.remaining_s(now), 1),
            "decisionId": self.decision_id,
            "reportedAt": now.isoformat(),
        }


def vehicles_payload() -> list[dict]:
    result = []
    for vid in traci.vehicle.getIDList():
        x, y = traci.vehicle.getPosition(vid)
        lon, lat = traci.simulation.convertGeo(x, y)
        speed = max(0.0, traci.vehicle.getSpeed(vid))
        result.append({
            "externalId": vid[:64],
            "lat": round(lat, 7),
            "lon": round(lon, 7),
            "speedMps": round(speed, 2),
            "headingDeg": round(traci.vehicle.getAngle(vid) % 360.0, 1) if speed >= 0.5 else None,
            "accuracyM": 1.0,
            "vehicleType": "AMBULANCE" if traci.vehicle.getVehicleClass(vid) == "emergency" else "NORMAL",
            "emergency": traci.vehicle.getVehicleClass(vid) == "emergency",
        })
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--backend", default="http://localhost:8000")
    parser.add_argument("--key", default=os.environ.get("SMART_TRAFFIC_CONTROLLER_KEY"))
    parser.add_argument("--sumocfg", default=str(HERE / "network" / "corridor.sumocfg"))
    parser.add_argument("--gui", action="store_true")
    parser.add_argument("--steps", type=int, default=0, help="Stop after N simulated seconds (0 = run until closed)")
    parser.add_argument("--fast", action="store_true", help="Do not wait for wall-clock time between steps")
    parser.add_argument("--tls", action="append", default=[], help="Map CODE=SUMO_TLS_ID when ids differ")
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    logging.getLogger("httpx").setLevel(logging.WARNING)
    if not args.key:
        raise SystemExit("A controller key is required (--key or SMART_TRAFFIC_CONTROLLER_KEY).")

    api = httpx.Client(base_url=f"{args.backend.rstrip('/')}/api/v1", headers={"X-Controller-Key": args.key}, timeout=10)
    ping = api.get("/controller/ping")
    ping.raise_for_status()
    scope = ping.json()["intersectionCodes"]
    log.info("Controller key OK (%s), scope %s", ping.json()["name"], scope)

    traci.start([sumo_binary(args.gui), "-c", args.sumocfg, "--no-step-log", "true", "--time-to-teleport", "300"])
    mapping = dict(item.split("=", 1) for item in args.tls)
    tls_ids = set(traci.trafficlight.getIDList())
    lights = {code: TrafficLight(code, mapping.get(code, code)) for code in scope if mapping.get(code, code) in tls_ids}
    missing = [c for c in scope if c not in lights]
    if missing:
        log.warning("No SUMO traffic light for %s (use --tls CODE=ID)", missing)

    step = 0
    try:
        while args.steps == 0 or step < args.steps:
            started = time.monotonic()
            traci.simulationStep()
            step += 1
            now = utcnow()
            try:
                api.post("/controller/observations", json={"observedAt": now.isoformat(), "vehicles": vehicles_payload()})
                if step % 2 == 1:
                    data = api.get("/controller/decisions").json()
                    decisions = {d["intersectionCode"]: d for d in data["decisions"]}
                    for plan in data["plans"]:
                        light = lights.get(plan["intersectionCode"])
                        if light is not None:
                            light.set_plan(plan)
                            light.apply(decisions.get(plan["intersectionCode"]))
            except httpx.HTTPError as exc:
                log.warning("Backend unreachable (%s); lights keep running their local plan", exc)
            for light in lights.values():
                light.step(1.0, now)
            if step % 2 == 0:
                states = [s for s in (light.report(now) for light in lights.values()) if s]
                try:
                    if states:
                        api.post("/controller/signal-states", json={"states": states})
                except httpx.HTTPError:
                    pass
            if step % 30 == 0:
                log.info("t=%ss vehicles=%d lights=%s", step, traci.vehicle.getIDCount(),
                         {c: f"{l.signal.phase.name}:{l.signal.state.value}" for c, l in lights.items() if l.signal})
            if not args.fast:
                time.sleep(max(0.0, 1.0 - (time.monotonic() - started)))
    except KeyboardInterrupt:
        pass
    finally:
        traci.close()
        api.close()


if __name__ == "__main__":
    main()
