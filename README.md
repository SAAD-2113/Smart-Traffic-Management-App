# Smart Traffic Management System

Final-year project: smartphone vehicle telemetry feeding a multi-intersection adaptive traffic
management engine, with a driver app, a traffic-manager dashboard, SUMO simulation and a demo mode.

- **Two modes, chosen when the app starts:** **Hardware Prototype**, a read-only offline monitor
  for the physical ESP32 intersection (no login), and **Software System**, the full app below
  (see `docs/HARDWARE_MODE.md`).
- **Driver / vehicle app (Android):** register a vehicle, get a Vehicle ID, start/stop GPS tracking with
  an offline queue, trip history, and emergency mode for authorized emergency vehicles.
- **Manager app (Android and web):** a traffic control centre dashboard that shows each
  intersection's signal mode: fixed-time by default, switched automatically to adaptive timing when
  congestion is significant. Each status gives the reason, the traffic behind it and the calculated
  green/yellow/red against the fixed plan. The live map shows the signal lights at every
  intersection. Also: vehicles, intersections with observed / calculated / estimated traffic
  metrics, traffic analysis, emergency authorizations and events, signal plans, mode-change history,
  and demo simulation controls including a simulated rush hour.
- **Backend:** FastAPI + PostgreSQL. Server-side validation of every packet, roles, emergency
  authorization, a traffic engine that runs every 2 s, a WebSocket feed for dashboards, and an API for
  machine clients (SUMO bridge, Raspberry Pi controllers).

Signal timings produced by the engine are **advisory and for simulation/prototype use**. Simulated
data (demo fleet, SUMO) is always labelled as such and kept separate from real vehicles.

| Folder | Contents | Status |
|---|---|---|
| `backend/` | FastAPI service: auth, roles, vehicles, devices, tracking, telemetry, emergency, intersections, traffic, signals, live WebSocket, demo, controller API | Phases 2-9 done |
| `traffic_engine/` | Pure-Python traffic analysis (mapping, metrics, data quality, network state), controllers (fixed, demand-proportional with coordination, emergency priority) and the demo fleet simulator | Done |
| `mobile/` | Flutter app: driver and manager roles in one app (Android APK + web dashboard) | Done |
| `sumo_bridge/` | TraCI bridge between Eclipse SUMO and the backend, corridor generator | Done |
| `tools/` | `hardware_test_server.py`: imitates the ESP32 controller for testing Hardware mode | |
| `infra/` | Docker Compose for PostgreSQL (+PostGIS) | Done |
| `Dockerfile`, `render.yaml` | Server image and one-click Render deployment | Done |
| `docs/` | Architecture, API, security and privacy, testing, Windows setup, ADRs | |
| `dist/` | The built Android APK | |

## Start here

1. Run the server: **in the cloud** with `docs/DEPLOY_CLOUD.md` (no PC needed, phones connect from
   anywhere), or **on your PC** with `docs/SETUP_WINDOWS.md` (phones on the same Wi-Fi).
2. `docs/ARCHITECTURE.md`: system design, telemetry packet spec, traffic processing, emergency flow.
3. `docs/HARDWARE_MODE.md`: the ESP32 intersection monitor (Hardware mode), its simulator and test server.
4. `docs/API.md`, `docs/SECURITY_AND_PRIVACY.md`, `docs/TESTING.md`.

## Quick start (development)

```powershell
cd backend; copy .env.example .env      # set JWT_SECRET and DATABASE_URL (SQLite works for a demo)
uv sync; uv run alembic upgrade head
uv run python -m scripts.create_user --role MANAGER --email manager@example.com --name "Traffic Manager"
uv run python -m scripts.seed_intersections          # policy AUTO: fixed-time, adaptive when congested
uv run uvicorn app.main:app --host 0.0.0.0 --port 8000
```

Install `dist/smart-traffic-v1.2.0-arm64-v8a.apk` (or the universal `dist/smart-traffic-v1.2.0.apk`) on an Android phone on the same Wi-Fi, tap **Server** on the
login screen and enter `http://<PC IP>:8000`. For a cloud server, enter its `https://` address instead.

## Tests

`traffic_engine`: 56 · `backend`: 116 · `mobile`: 67 (see `docs/TESTING.md`).
