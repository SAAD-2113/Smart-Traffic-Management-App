# SUMO bridge

Connects an [Eclipse SUMO](https://eclipse.dev/sumo/) simulation to the Smart Traffic backend over TraCI.
It is a **simulation** tool: it lets you test the traffic engine and the adaptive controllers against a
microscopic simulator where every vehicle is known, instead of the phone-probe data from real vehicles.

```
SUMO (corridor I1-I4) ──TraCI──> bridge.py ──HTTPS + X-Controller-Key──> backend
   ▲                                │   POST /controller/observations   (every simulated second)
   │ setRedYellowGreenState         │   GET  /controller/decisions      (every 2 s)
   └────────── VirtualSignal <──────┘   POST /controller/signal-states  (every 2 s)
```

- SUMO vehicles are sent as **observations** (source `SUMO`), never as registered vehicles, and are
  never mixed with phone telemetry in the database. The engine treats SUMO as fully observed
  (no penetration-rate scaling).
- Vehicles of vClass `emergency` are reported as `AMBULANCE` with `emergency=true`, so the engine's
  emergency-priority controller can react to them.
- Each SUMO traffic light is driven by the same `VirtualSignal` the demo fleet uses. A backend decision
  is applied only while it is valid (`validUntil`); minimum green, yellow and all-red times are always
  honoured; without a valid decision (or if the backend is unreachable) the light runs its fixed plan.
- The bridge maps SUMO's controlled links to plan phases by comparing each incoming lane's direction
  with the approach bearings the backend sends (`approachBearings`). A movement that must yield in
  SUMO's own program (lower-case `g`, e.g. a permissive left turn) keeps yielding.

## Setup

Requires Python 3.11+ and [uv](https://docs.astral.sh/uv/). SUMO itself comes from the `eclipse-sumo`
wheel, so no separate install is needed (an existing install works too: set `SUMO_HOME`).

```powershell
cd sumo_bridge
uv sync
uv run python build_network.py      # writes network/corridor.{nod,edg,net,rou}.xml + corridor.sumocfg
```

`network/corridor.json` holds the corridor: the same placeholder I1-I4 coordinates as
`backend/scripts/seed_intersections.py`, arm length, speed limit, flows and how often an ambulance is
sent. Junction ids in SUMO equal the backend intersection codes. If you edit the backend intersections,
edit this file to match and rebuild. For an existing SUMO network with different ids, use
`--tls I1=<sumo tls id>`.

## Run

1. Start the backend (see `backend/README.md`). Stop the demo simulation if it is running
   (Settings → Demo simulation), so SUMO and demo data are not mixed.
2. As an admin, create a controller key for the bridge (the key is shown once):

   ```http
   POST /api/v1/admin/controller-clients
   Authorization: Bearer <admin access token>

   {"name": "sumo-corridor", "kind": "SUMO_BRIDGE", "intersectionIds": ["<I1 id>", "<I2 id>", "<I3 id>", "<I4 id>"]}
   ```

3. Run the bridge:

   ```powershell
   $env:SMART_TRAFFIC_CONTROLLER_KEY = "stc_..."
   uv run python bridge.py --backend http://localhost:8000          # real time
   uv run python bridge.py --backend http://localhost:8000 --gui    # with sumo-gui
   uv run python bridge.py --fast --steps 600                       # as fast as possible, 10 simulated minutes
   ```

   The manager app then shows the intersections with source `SUMO`, the signal states reported by the
   bridge (source `SUMO_BRIDGE`, connected) and the engine's advisory decisions.

`--fast` runs the simulation faster than real time. Decisions carry wall-clock validity (15 s), so in
fast mode one decision covers many simulated seconds; use real time when evaluating controllers.

## Comparing controllers

Set an intersection's control mode in the app (Intersections → an intersection → Configuration) or with
`PATCH /api/v1/intersections/{id}` (`controllerType`: `FIXED` or `ADAPTIVE`), run the same scenario
for each, and compare waiting time and queue length in Traffic Analysis / History. SUMO's own outputs
(`--tripinfo-output`, `--summary-output`, added to the `traci.start` call or the `.sumocfg`) give an
independent measurement.

## Limits

- The generated corridor is a simple four-junction arterial with single-lane side streets; it is a test
  scenario, not a calibrated model of real roads.
- One bridge process per backend. Traffic lights outside the key's scope are left under SUMO's control.
