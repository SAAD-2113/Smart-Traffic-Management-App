# Smart Traffic Management System — Architecture

Status: accepted, and implemented through Phase 10 (prototype).
This document is the design reference. `docs/API.md` lists every endpoint, and
`docs/SECURITY_AND_PRIVACY.md`, `docs/TESTING.md` and `docs/SETUP_WINDOWS.md` cover their own topics.

---

## A. System understanding

The system is a **multi-intersection adaptive traffic management prototype**. Its first real
data source is a fleet of participating smartphones in vehicles.

- The **mobile app** is the *vehicle data collection and communication layer*. It turns the
  phone's GNSS fixes into validated telemetry packets and delivers them reliably. For
  authorised emergency vehicles it also carries a deliberate, server-verified emergency status.
  It makes **no traffic decisions**.
- The **backend** authenticates people and machines. It re-validates every packet, because
  the client is never trusted. It keeps each vehicle's live state and history and hands
  observations to the traffic engine.
- The **traffic engine** is a pure-Python library with no web or database code. It maps
  vehicles to intersections and approaches, then aggregates observations into
  **observed**, **calculated** and **estimated** metrics. It builds a network-wide traffic
  state that includes upstream and downstream context. Pluggable controllers turn that state
  into **advisory** signal-timing decisions.
- **Signal actuators** apply decisions. These are Raspberry Pi controllers, the SUMO bridge,
  or the built-in demo simulator. Every actuator enforces its own safety limits and falls
  back to fixed-time control on its own (ADR 0001).
- The **manager app** shows the whole picture: vehicles, the map, intersections, congestion,
  emergencies, signal decisions and history.

Sources other than phones plug into the same engine input: SUMO (TraCI), cameras and
roadside sensors. The engine does not care where an observation came from, only how
trustworthy it is.

## B. Architecture

```text
┌──────────────────────┐   HTTPS REST (batched telemetry, auth)   ┌──────────────────────────────────────────┐
│  Flutter app         │ ───────────────────────────────────────▶ │  FastAPI backend (single process)         │
│  ─ Driver mode       │                                          │                                          │
│    GPS (foreground   │ ◀─────────────────────────────────────── │  api/v1  ── auth, me, vehicles, tracking, │
│    service) → queue  │   JSON responses (per-packet results,    │            telemetry, emergency, manager, │
│    → uploader        │   authoritative emergency status)        │            intersections, signals,        │
│  ─ Manager mode      │                                          │            traffic, demo, admin,          │
│    dashboard, map,   │ ◀══════ WebSocket /live/ws (push) ══════ │            controller (machine keys)      │
│    analysis, control │                                          │  services ── validation, ingest, live     │
└──────────────────────┘                                          │            state, emergency, signal plans │
                                                                  │  runner  ── every 2 s: engine cycle,      │
┌──────────────────────┐  HTTPS + X-Controller-Key                │            housekeeping, WS broadcast     │
│ Raspberry Pi signal  │ ◀──── decisions (poll) ───────────────── │  demo    ── simulated fleet + virtual      │
│ controllers (I1..In) │ ───── signal states ───────────────────▶ │            signals (DEMO_MODE only)       │
└──────────────────────┘                                          │                                          │
┌──────────────────────┐  HTTPS + X-Controller-Key                │         ┌──────────────────────────────┐ │
│ SUMO + sumo_bridge   │ ───── observations (vehicles) ─────────▶ │         │ traffic_engine (pure Python) │ │
│ (TraCI)              │ ◀──── decisions ──────────────────────── │ ──────▶ │ mapping → aggregation →      │ │
└──────────────────────┘                                          │         │ network state → controllers  │ │
┌──────────────────────┐                                          │         └──────────────────────────────┘ │
│ Camera / sensors     │ ───── observations (counts) ───────────▶ │                                          │
│ (future)             │                                          └───────────────────┬──────────────────────┘
└──────────────────────┘                                                              │ SQLAlchemy (async)
                                                                                      ▼
                                                                   ┌──────────────────────────────────────┐
                                                                   │ PostgreSQL 16 (+PostGIS available)    │
                                                                   │ users, vehicles, devices, telemetry,  │
                                                                   │ live states, sessions, emergencies,   │
                                                                   │ intersections, metrics, signal data   │
                                                                   └──────────────────────────────────────┘
```

The traffic pipeline inside the backend:

```text
Telemetry / SUMO / camera observation
      ↓ validation (server-side, per packet)
      ↓ vehicle live state (+ history row)
      ↓ vehicle → intersection / approach / link mapping          (traffic_engine.mapping)
      ↓ aggregation per approach and intersection                 (traffic_engine.aggregation)
      ↓ observed → calculated → estimated metrics
      ↓ network traffic state (upstream arrivals, downstream load) (traffic_engine.network)
      ↓ SignalController.decide()                                 (traffic_engine.control)
      ↓ advisory SignalDecision (validUntil, safety limits)
      ↓ actuator (Pi / SUMO / virtual demo signal) → reports SignalState back
```

### Application architecture (Flutter)

```text
lib/
  core/      config (server URL), HTTP client with token refresh, secure token store, theme, units
  data/      models (JSON ↔ Dart), repositories (one per API area), local telemetry queue (SQLite)
  services/  location (GPS + permission + quality), tracking (collect → queue → upload), live socket
  features/  auth · driver (home, tracking, emergency, trips, profile) · manager (dashboard, vehicles,
             map, intersections, analysis, emergency, signals, history, settings)
  widgets/   reusable status chips, metric cards, empty/error/loading states
```

UI widgets never talk HTTP directly. They use controllers (`ChangeNotifier`), which use
repositories, which use the API client. One APK contains both roles. The **server** decides the
role at login, and the app shows the driver or the manager shell to match.

### Backend architecture

`api` (thin HTTP layer) → `services` (business rules, transactions, audit) → `repositories` /
SQLAlchemy models. `core` holds config, security, errors and rate limits. `runner` holds the
periodic engine loop. `realtime` holds the WebSocket hub. The engine is imported as a library.
This layering is the same one Phase 2 set up.

## C. Technology stack

| Layer | Choice | Alternatives considered and why not |
|---|---|---|
| Mobile | **Flutter 3.47 / Dart 3.13** | React Native: similar, but Flutter gives one codebase for the Android app *and* a web build of the manager dashboard. Native Android: double the work for the dashboard. |
| GPS | `geolocator` 14 with an Android **foreground service** | Background-location permission is not needed and draws Play-policy scrutiny. A visible foreground service is honest with the driver and survives backgrounding. |
| Local queue | `sqflite` (SQLite) | shared_preferences rewrites the whole blob on each write and loses data on process death. |
| Token storage | `flutter_secure_storage` (Android Keystore) | Plain preferences would expose the refresh token. |
| Maps | **OpenStreetMap** via `flutter_map` | Google Maps / Mapbox need an API key embedded in the APK, plus billing. The tile URL is configurable. |
| Charts | `fl_chart` | — |
| Backend | **Python 3.12 + FastAPI** (Phase 2) | Node.js is fine, but the traffic engine and SUMO/TraCI are Python, so one language keeps the engine importable everywhere. |
| Database | **PostgreSQL 16** (PostGIS image available) | Firestore: rules-based validation is too weak for untrusted telemetry, and relational integrity (vehicle ↔ device ↔ session) matters. Distances use haversine in Python; PostGIS is kept for later spatial queries. |
| Telemetry transport | **HTTPS REST, batched** | MQTT needs a broker plus per-device credentials and adds little for 0.5 Hz uploads. REST also gives natural backfill batches, per-packet results and standard auth and rate limiting. |
| Live dashboard | **WebSocket** (FastAPI) | Polling works too and is kept as a fallback. Firebase or Supabase Realtime would split the source of truth. |
| Machine clients | HTTPS + API key, polling (ADR 0001/0002) | See ADR 0002. |
| Simulation | Built-in demo fleet + **Eclipse SUMO** via TraCI | SUMO is optional and never required by the app. |

Cost: every component is free and open source, and runs on one laptop.

## D. Database schema

All timestamps are timezone-aware UTC. All ids are UUIDs, except append-only logs, which use
bigint. Enums are stored as VARCHAR with a CHECK constraint, so adding a value is a simple
migration.

```text
users ─┬─< refresh_tokens            (rotating sessions, reuse detection)
       ├─< password_reset_tokens
       └─< vehicles ─┬─< devices                  (≤1 ACTIVE per vehicle, partial unique index)
                     ├─< emergency_authorizations  (PENDING → APPROVED/REJECTED → REVOKED)
                     ├─< emergency_events          (ACTIVE → ENDED, reason)
                     ├─< tracking_sessions ─< vehicle_telemetry
                     └─1 vehicle_live_states      (latest fix, upserted)

intersections ─┬─< intersection_approaches (bearing, lanes, zone length, upstream intersection)
               ├─< intersection_links      (directed I1→I2, distance, free-flow speed)
               ├─1 signal_plans            (phases JSON: approaches, min/max/fixed green, yellow, all-red)
               ├─< signal_decisions        (advisory, validUntil, algorithm, inputs)
               ├─< signal_states           (reported by actuators)
               └─< traffic_metrics         (30 s history snapshots per intersection/approach)

controller_clients ─< controller_client_scopes >─ intersections
audit_logs, code_counters
```

| Table | Key columns (new in Phases 3–8 unless marked P2) |
|---|---|
| users (P2) | id, email, phone, password_hash (argon2id), full_name, role END_USER/MANAGER/ADMIN, is_active |
| vehicles (P2) | id **(the real vehicle id)**, code `VH-0001` / `EV-0001` / `SIM-0001` (display label), owner_user_id, vehicle_type NORMAL/AMBULANCE/FIRE_TRUCK/POLICE, display_name, registration_number, is_simulated, status |
| devices (P2) | id, vehicle_id, installation_id (random per app install), platform, model, app_version, status, last_seen_at |
| emergency_authorizations (P2) | vehicle_id, status, requested_by, reviewed_by, reviewed_at, valid_until, notes |
| **tracking_sessions** | id, vehicle_id, device_id, started_at, ended_at, end_reason, packet_count, distance_m, max_speed_mps, last_seq, last_recorded_at |
| **vehicle_telemetry** | id (bigint), vehicle_id, session_id, source MOBILE/SIMULATOR, recorded_at (device), received_at (server), lat, lon, accuracy_m, speed_mps, speed_source GPS/DERIVED, heading_deg, altitude_m, emergency (**server-decided**), is_mock, is_live, usable, intersection_id, approach_id, zone |
| **vehicle_live_states** | vehicle_id (PK), same fields as the latest accepted live packet, plus gps_quality |
| **emergency_events** | id, vehicle_id, session_id, status ACTIVE/ENDED, started_at, ended_at, end_reason DRIVER/MANAGER/TIMEOUT/AUTH_REVOKED/TRACKING_STOPPED, ended_by |
| **signal_plans** | intersection_id (unique), phases JSON, min_cycle_s, max_cycle_s, updated_by |
| **signal_decisions** | id, intersection_id, created_at, valid_until, algorithm, cycle_s, phase_greens JSON, priority_phase, reason, inputs JSON |
| **signal_states** | id, intersection_id, reported_at, received_at, phase_name, state GREEN/YELLOW/ALL_RED, remaining_s, mode, decision_id, client_id |
| **traffic_metrics** | id, intersection_id, approach_id (null = whole intersection), window_end, observed_* , calculated_*, estimated_*, congestion_level, data_quality, sources |

`userId`, `vehicleId` and `deviceId` are separate concepts. A user owns up to N vehicles. A
vehicle has one active device (phone) at a time, and a phone can be replaced without changing
the vehicle. Every telemetry row belongs to the vehicle, not the phone or the person.

## E. API design (summary — full reference in `docs/API.md`)

Base path `/api/v1`. JSON uses camelCase. Errors always look like
`{"error": {"code", "message", "details", "requestId"}}`.

| Area | Endpoints | Auth |
|---|---|---|
| Auth (P2) | `POST /auth/register · /login · /refresh · /logout · /password/forgot · /password/reset · /password/change` | public / user |
| Me (P2) | `GET/PATCH /me`, `GET /me/vehicles` | user |
| Vehicles (P2) | `POST /vehicles`, `GET /vehicles/{id}`, devices bind/list/unbind | END_USER (owner) |
| Tracking | `POST /vehicles/{id}/tracking/start · /stop`, `GET /vehicles/{id}/tracking/sessions`, `GET /vehicles/{id}/telemetry/latest` | owner + bound device |
| Telemetry | `POST /vehicles/{id}/telemetry` (batch ≤100) | owner + `X-Installation-Id` of the active device |
| Emergency (driver) | `GET /vehicles/{id}/emergency`, `POST /vehicles/{id}/emergency/start · /stop`, `POST /vehicles/{id}/emergency/authorization-request` | owner, authorised vehicle |
| Manager | `GET /manager/vehicles[/{id}]`, `GET /manager/live/vehicles`, `GET /manager/vehicles/{id}/telemetry`, `PATCH /manager/vehicles/{id}/status` | MANAGER/ADMIN |
| Emergency (manager) | `GET /emergency/active`, `GET /manager/emergency/events`, `POST /manager/emergency/events/{id}/end`, `GET /manager/emergency/authorizations`, `POST …/{id}/approve · /reject`, `POST /manager/vehicles/{id}/emergency-authorization/revoke` | MANAGER/ADMIN |
| Intersections (P2) | CRUD + approaches + links | MANAGER/ADMIN |
| Traffic | `GET /traffic/overview`, `GET /traffic/intersections[/{id}]`, `GET /traffic/intersections/{id}/history`, `GET /traffic/history` | MANAGER/ADMIN |
| Signals | `GET /signals/overview`, `GET/PUT /intersections/{id}/signal-plan`, `GET /intersections/{id}/signal-decisions` | MANAGER/ADMIN |
| Live | `WS /live/ws` (first message authenticates) | MANAGER/ADMIN |
| Demo | `GET /demo/status`, `POST /demo/start · /stop` | MANAGER/ADMIN, only if `DEMO_MODE=true` |
| Controller | `GET /controller/ping · /decisions · /traffic-state`, `POST /controller/signal-states · /observations` | `X-Controller-Key`, scoped |
| Admin (P2) | managers, user status, controller keys | ADMIN |

Rate limits: login 5/min, register 3/h, telemetry 240/min per IP, and one packet per 0.5 s per
vehicle. Other limits are listed in `docs/API.md`.

## F. User roles and permissions

Roles live in the database only. The JWT carries the user id, never the role. Every request
re-reads the user, so a disabled account or a changed role takes effect at the next request.
Emergency capability is **not a role**. It is a per-vehicle authorisation that a manager
approves.

| Capability | END_USER | MANAGER | ADMIN |
|---|:-:|:-:|:-:|
| Register, log in, reset or change own password, edit own profile | ✓ | ✓ | ✓ |
| Register own vehicles (≤3), bind this phone, start/stop tracking, send telemetry | ✓ | – | – |
| View own trips and own latest telemetry | ✓ | – | – |
| Activate/deactivate emergency mode (own *authorised* vehicle only) | ✓ | – | – |
| View all vehicles (operational fields only: code, type, status) and live telemetry | – | ✓ | ✓ |
| View traffic metrics, history, signal state, emergencies | – | ✓ | ✓ |
| Suspend / reactivate a vehicle (with reason, audited) | – | ✓ | ✓ |
| Approve / reject / revoke emergency authorisation; force-end an emergency | – | ✓ | ✓ |
| Configure intersections, approaches, links, signal plans, control policy (AUTO/FIXED/ADAPTIVE) | – | ✓ | ✓ |
| Start/stop the demo simulation (DEMO_MODE only) | – | ✓ | ✓ |
| See owner identity of a vehicle | own | ✗ | ✓ |
| See registration number | own | only in the authorisation review | ✓ |
| Create manager accounts, disable users, create/revoke controller keys | – | – | ✓ |
| Change another user's email or password, delete accounts | ✗ | ✗ | ✗ (not offered) |

Managers can *see and operate* the traffic system. They cannot take over or impersonate
end-user accounts.

## G. Data flow — from phone GPS to traffic management

1. **Collect.** Once tracking starts, a foreground service gets a GNSS fix every ~1 s.
   Fixes worse than 100 m are dropped on the phone and shown as "GPS poor". If the platform
   reports no speed, speed is derived from the last two good fixes (`speedSource=DERIVED`).
2. **Packetise.** Each fix becomes a packet (see the packet spec below) with a per-session
   `seq`, and is written to the local SQLite queue first. Nothing is sent straight from the
   GPS callback.
3. **Upload.** Every 2 s the uploader sends the oldest ≤100 queued packets to
   `POST /vehicles/{id}/telemetry`. The request carries the bearer token and the
   installation id. Any packet the server answered for, accepted or rejected, is removed
   from the queue.
4. **Validate (server).** The server checks the device binding and the open session, then
   each packet: ranges, timestamp window, ordering (replay), frequency, jump plausibility,
   accuracy class and the mock flag. It returns a result per packet.
5. **Store.** Accepted packets become `vehicle_telemetry` rows. Packets no more than 15 s old
   at arrival (`is_live`) also update `vehicle_live_states`. Older, backfilled packets go to
   history only.
6. **Map.** The engine maps each live, usable fix to an intersection zone (CORE / APPROACH /
   DEPARTURE), an approach (by heading) or a link between intersections.
7. **Aggregate.** Every 2 s the runner builds per-approach and per-intersection metrics and
   the network state. Every 30 s it saves a snapshot to `traffic_metrics`.
8. **Decide.** The mode state machine (see "Signal-control modes" below) picks fixed-time,
   adaptive or emergency priority for each intersection and explains why. In adaptive or
   emergency mode the controller produces an advisory decision with `validUntil`. Actuators
   poll for it and report their actual state.
9. **Present.** A WebSocket pushes a snapshot (vehicles, intersections, emergencies, summary)
   to manager apps after each cycle. REST endpoints serve the same data for polling and
   history.

### Telemetry packet specification (v1)

`POST /api/v1/vehicles/{vehicleId}/telemetry`
Headers: `Authorization: Bearer <access token>`, `X-Installation-Id: <installation id>`

```json
{
  "sessionId": "8f0c…",
  "packets": [
    {
      "seq": 1532,
      "recordedAt": "2026-09-30T15:20:10.250Z",
      "lat": 31.5204,
      "lon": 74.3587,
      "accuracyM": 6.4,
      "speedMps": 11.81,
      "speedAccuracyMps": 0.4,
      "speedSource": "GPS",
      "headingDeg": 180.2,
      "altitudeM": 214.0,
      "emergency": false,
      "mocked": false
    }
  ]
}
```

| Field | Req. | Type | Rule |
|---|:-:|---|---|
| sessionId | ✓ | UUID | Must be the vehicle's open tracking session |
| seq | ✓ | int ≥ 0 | Strictly increasing within the session |
| recordedAt | ✓ | ISO-8601 UTC with offset | Device time of the fix. Not > 30 s in the future, not > 10 min old |
| lat / lon | ✓ | float | WGS-84 degrees, [-90, 90] / [-180, 180], not exactly (0, 0) |
| accuracyM | ✓ | float | Horizontal accuracy radius (m), 0 < a ≤ 500. **≤ 50 m** counts as *usable* for metrics |
| speedMps | – | float \| null | 0 ≤ v ≤ 70 m/s (252 km/h). Null means unknown, not zero |
| speedAccuracyMps | – | float \| null | ≥ 0 |
| speedSource | – | `GPS` \| `DERIVED` | Defaults to GPS when speed is present |
| headingDeg | – | float \| null | [0, 360). Null when stationary or unknown |
| altitudeM | – | float \| null | −500 … 9000 |
| emergency | ✓ | bool | What the app *believes*. The server stores its own authoritative value |
| mocked | ✓ | bool | The Android mock-location flag. Accepted, but excluded from metrics |

The packet has no `vehicleId`. The vehicle is identified by the URL, and ownership comes from
the token plus the bound installation, so a packet cannot claim to be another vehicle.

**Units.** The backend stores and exchanges **SI units**: m/s, metres, degrees and UTC. GNSS
APIs report m/s natively, SUMO uses m/s, and physics (ETA, density) needs no conversions.
The UI shows **km/h** (`km/h = m/s × 3.6`).

**Staleness.** `ageAtArrival = receivedAt − recordedAt`.
- ≤ 15 s → **live**: updates live state and feeds metrics and emergency tracking.
- 15 s – 10 min → **backfill**: stored for history and trips only.
- \> 10 min → rejected `STALE_TIMESTAMP`. The app also discards these before upload.
A vehicle whose last live packet is older than 15 s shows as **STALE**. After 5 minutes it is
**OFFLINE** and leaves every metric.

**Per-packet rejections:** `INVALID_COORDINATES`, `INVALID_ACCURACY`, `LOW_ACCURACY`,
`INVALID_SPEED`, `UNREALISTIC_SPEED`, `INVALID_HEADING`, `INVALID_ALTITUDE`,
`FUTURE_TIMESTAMP`, `STALE_TIMESTAMP`, `DUPLICATE_OR_OUT_OF_ORDER`, `TOO_FREQUENT`,
`IMPLAUSIBLE_JUMP`. Request-level errors: 401/403 for auth; 404 for someone else's vehicle;
409 `DEVICE_NOT_BOUND`, `VEHICLE_NOT_ACTIVE` or `SESSION_NOT_ACTIVE`; 422 for a malformed body;
429 when rate limited.

### GPS strategy and failure handling

| Situation | Behaviour |
|---|---|
| Permission denied | Tracking cannot start. The screen explains why and links to app settings. "Deny forever" is detected. |
| Location services off | Status reads "GPS off", with a button that opens the location settings. |
| No fix yet / tunnel | Status reads "Searching…" after 10 s without a fix. Nothing is fabricated. |
| Poor accuracy | > 100 m: dropped on the phone. 50–100 m: sent, stored, and marked not usable. The UI shows the quality level. |
| Speed unavailable | Derived from consecutive good fixes (marked DERIVED), else null. |
| Backgrounded | A foreground service with a persistent notification keeps GPS alive. No background-location permission is needed. |
| No internet | Packets queue in SQLite (cap 3 600 ≈ 1 h). Upload backs off 2 → 30 s. The UI shows "Offline — N queued". |
| Unstable network | Batches are idempotent. Ordering is preserved because the queue is FIFO and the server rejects duplicates. |

### Offline data policy

Traffic control needs *current* data, so packets are only useful live for 15 seconds.
Queued packets are still uploaded when the connection returns, up to 10 minutes old, because
they complete trip history and the research dataset. The server marks them `is_live=false`,
so they never move a live metric, a signal decision or an emergency. Packets older than
10 minutes are discarded on the phone. They would be rejected anyway, and they have no
operational value.

## H. Emergency vehicle flow

```text
Driver registers vehicle as AMBULANCE / FIRE_TRUCK / POLICE (+ registration number)
        ↓  authorisation PENDING          (registering grants nothing)
Manager reviews (type + registration number) → APPROVE (optional expiry) / REJECT
        ↓  vehicle.emergencyAuthorized = true
Driver starts tracking → emergency screen → press-and-hold 2 s → confirm dialog
        ↓  POST /emergency/start  (server re-checks authorisation, open session, recent live fix)
emergency_event ACTIVE  ──▶ WebSocket event EMERGENCY_STARTED to every manager
        ↓  live telemetry now stored with emergency=true (server-decided)
Engine: emergency vehicle mapped to approach, distance and ETA to the next intersection
        ↓  ETA ≤ 60 s → EmergencyPriority controller issues an advisory priority phase
Actuator (SUMO / demo virtual signal) grants priority after minimum-green and clearance times
        ↓
Ends when: driver stops · manager force-ends · tracking stops · no live fix for 120 s ·
           60 min maximum · authorisation revoked   → EMERGENCY_ENDED event
```

Safeguards:
- **Authorisation is checked twice**, when an event starts and on every packet. The packet's
  `emergency` flag is only a hint.
- **Accidental activation is hard.** It needs a hold-to-activate button and a confirmation
  dialog. Deactivation is a single tap.
- **Emergencies expire on their own.** A forgotten or crashed app cannot hold priority forever.
- **Everything is audited**: start, stop, approve, reject, revoke and force-end.
- **Signal priority is a simulation and prototype feature only.** Decisions are advisory. The
  demo simulator and SUMO apply them. A hardware controller must enforce minimum green,
  yellow and all-red times locally and may refuse any decision (ADR 0001). Nothing in this
  project may drive real public traffic signals without certified safety engineering.

## I. Traffic processing

**Mapping** (`traffic_engine.mapping`). For each fresh, usable, non-mocked observation:
1. If it is within `radius_m` of an intersection, the zone is **CORE**, the vehicle is inside
   the junction.
2. If it is within `approach_radius_m`, the approach is chosen by comparing the travel
   direction with each approach's `travel_bearing_deg ± tolerance`. The travel direction is
   the heading, or the bearing to the centre when the vehicle is stationary. The vehicle
   must be moving *towards* the centre to count as **APPROACH**; otherwise it is
   **DEPARTURE**.
3. Otherwise, if it lies within 40 m (plus GPS accuracy) of a directed link segment and
   travels along it, it is **ON_LINK**. Its distance to the downstream intersection gives
   an ETA.

**Aggregation** (`traffic_engine.aggregation`), per approach and per intersection:

| Kind | Metric | Definition |
|---|---|---|
| Observed | vehicleCount, stoppedCount, emergencyCount, sampleCount | Distinct probe vehicles in APPROACH+CORE zones. *Stopped* means v < 1.5 m/s |
| Observed | avg / min / max speed | Over vehicles with a known speed |
| Calculated | speedRatio | avgSpeed ÷ approach free-flow speed |
| Calculated | averageWaitingTimeS | Mean time the currently stopped vehicles have been stopped in the approach, tracked across cycles |
| Calculated | expectedArrivals60s | Vehicles on upstream links with ETA ≤ 60 s |
| Estimated | estimatedVehicleCount | observed ÷ `assumed_penetration_rate` (the share of vehicles running the app, 5 % by default) |
| Estimated | densityVehPerKmLane | estimated count ÷ (zone length km × lanes) |
| Estimated | congestionLevel | The worse of a speed-ratio class (≥0.7 LOW, ≥0.4 MODERATE, ≥0.2 HIGH, else SEVERE) and a density class (<15, <30, <50, ≥50 veh/km/lane) |
| Meta | dataQuality | NONE (0 vehicles) · LOW (1–2) · MEDIUM (3–9) · HIGH (≥10) |

**No data means UNKNOWN, never LOW.** One phone at 5 % penetration is weak evidence, and
every estimated number carries its data quality so the UI and controllers can discount it.
Detector counts from SUMO or cameras are direct counts and are *not* scaled by penetration.

**Network state** (`traffic_engine.network`). Each intersection state includes:
- **upstream**: for every incoming link, the probe vehicles on it, their mean speed, and
  expected arrivals within 60 s;
- **downstream**: the congestion level of every intersection this one feeds, used for
  spill-back protection;
- **emergency approaches**: vehicle, approach, distance and ETA.

## Adaptive control interface

```python
class SignalController(Protocol):
    name: str
    def decide(self, state: IntersectionState, plan: SignalPlan,
               network: NetworkState, now: datetime) -> SignalDecision: ...
```

Controllers that are included (in `traffic_engine.control`):
- **FixedTimeController** — the configured plan. It is the baseline for comparison and the
  fallback.
- **DemandProportionalController** — *Webster-style* timing, *not* claimed optimal.
  - Phase demand = estimated queue + upstream arrivals (60 s), divided by an assumed
    saturation flow of 1 800 veh/h/lane.
  - Cycle C = (1.5 L + 5) / (1 − Y), clamped to the plan's [min, max] cycle and never
    shorter than the fixed plan's cycle. Adaptive timing moves green to the busier phase
    and lengthens the cycle under heavy demand; it does not cut the cycle below the
    configured plan. Plain Webster can do that for light demand, and then even the
    congested phase would get less green than fixed-time.
  - Green is split in proportion to each phase's flow ratio, clamped to its min/max green.
  - Green feeding a SEVERE downstream intersection is capped (gating).
  - With data quality NONE it falls back to the fixed plan and says so in `reason`.
- **EmergencyPriorityController** — wraps another controller. When an active emergency
  vehicle has ETA ≤ 60 s, it adds `priorityPhase` and a green request for that approach.

Every decision carries `algorithm`, `cycleS`, `phaseGreens[]`, `priorityPhase`, `reason`,
the `inputs` it used, and `validUntil`, 15 s after creation. An actuator ignores a decision
after `validUntil` and runs its local fixed plan instead.

## Signal-control modes: fixed-time and adaptive

Each intersection has a **control policy** (`intersections.controller_type`):

| Policy | Behaviour |
|---|---|
| `AUTO` (default) | Fixed-time while traffic is normal; adaptive timing while congestion is significant. |
| `FIXED` | Always the configured fixed-time plan (the manager's choice). |
| `ADAPTIVE` | Always calculated timing (the manager's choice). |

Emergency priority overrides every policy while an authorized emergency vehicle approaches.

The **mode** in force is one of `FIXED_TIME`, `ADAPTIVE` or `EMERGENCY_PRIORITY`. Under `AUTO` it
comes from a state machine in `traffic_engine.control.modes.ModeController`. The engine runs it
every cycle for every active intersection:

```
                      Traffic data (vehicle observations)
                                    |
                                    v
        Calculate congestion per intersection (each cycle), then average it
        over the last CONTROL_WINDOW_S seconds (rank mean of the levels)
                                    |
                +-------------------+--------------------+
                |                                        |
       Normal (below HIGH, or fewer           Congested (average >= HIGH and
       than CONTROL_MIN_VEHICLES)             >= CONTROL_MIN_VEHICLES vehicles)
                |                                        |
                v                                        v
        FIXED_TIME mode            held for CONTROL_ENTER_HOLD_S? -- no --> stay FIXED_TIME
        (configured plan)                        | yes                  ("Congestion building",
                ^                                v                       countdown shown)
                |                         ADAPTIVE mode
                |                (green calculated from demand)
                |                                |
                |      average <= LOW (or too few vehicles) for CONTROL_EXIT_HOLD_S
                +------ and at least CONTROL_MIN_ADAPTIVE_S in adaptive ----------+
                        ("Congestion cleared")        otherwise stay ADAPTIVE
                                                      ("Congestion easing")

  Data quality below CONTROL_MIN_DATA_QUALITY  ->  FIXED_TIME ("Not enough traffic data")
  Emergency vehicle with ETA <= 60 s           ->  EMERGENCY_PRIORITY, then back to the base mode
```

Design choices:
- **Hysteresis.** The machine enters adaptive at HIGH and leaves at LOW, with hold times and a
  minimum dwell, so the mode does not flap when traffic hovers around a threshold.
- **Averaging.** It switches on the averaged level, not on one noisy sample, and it ignores a
  few slow vehicles ("Light traffic": slow but fewer than `CONTROL_MIN_VEHICLES`).
- **Fixed-time is the safe default.** Fixed-time is used at start-up, without enough data,
  and whenever the adaptive controller has no demand data.
- **Configuration.** The fixed timings are the intersection's signal plan in the database,
  edited from the app. The thresholds are environment variables (`CONTROL_*` in
  `backend/.env.example`), validated at start-up and shown in the app
  (`GET /signals/control-config`).

Every status carries the reason with it. The app shows these fields; it does not work out
the mode itself:
- `mode`, `policy`, `reason` (enum), `headline` and `detail`, for example "High congestion
  detected" with "Average congestion is HIGH (on average 42 vehicles at 12 km/h over the last
  60 s) …";
- `pending`, for example "switching to adaptive in 12 s if congestion persists";
- `traffic`: the current and window-averaged vehicles, speed, waiting time and congestion,
  plus the worst approach;
- `fixedTiming` and `activeTiming` per phase (green, yellow, all-red, and red = cycle − green
  − yellow), with both cycle lengths, so the app can show "Green 48 s, +18 vs fixed".

Each mode change is stored in `signal_mode_events`, with the traffic figures behind it. It is
also pushed live as a `MODE_CHANGED` event. Events are kept for 90 days.

### Signal lights on the map

`displaySignal` on each intersection reports what the lights show: the phase, its state
(green, yellow or all-red), the seconds remaining, and one head per approach. The phase's
approaches show the phase colour and the others show red.
- **Connected controller.** The source is that controller's latest report (simulator,
  SUMO, or a future hardware controller).
- **No connected controller (display-only).** The server runs a **virtual controller** that
  steps through the same decisions, so the map still shows lights. These are labelled
  `VIRTUAL` ("Lights: virtual controller") and are never presented as street hardware.

The app places each head on the side its traffic arrives from (travel bearing + 180°). It
counts down on the server's clock.

## Inter-intersection coordination

The corridor is a directed graph of `intersection_links`, and nothing is hard-coded to four
intersections. Approaches name their upstream intersection. Each cycle the engine computes,
for every intersection, the arrivals approaching from each upstream link and the load of each
downstream intersection. The controllers use both: arrivals raise a phase's demand before the
platoon arrives, and a congested downstream node limits the green that would feed it.

## SUMO integration (Phase 8)

`sumo_bridge/` is a separate process with its own controller key (kind `SUMO_BRIDGE`,
scoped to the SUMO-mapped intersections). Each simulation second it:
1. reads vehicle positions through TraCI and converts them to lon/lat with
   `traci.simulation.convertGeo`;
2. posts them to `/controller/observations` with source `SUMO`;
3. fetches `/controller/decisions` and applies them to the traffic lights named by each
   intersection's `sumo_tls_id`, respecting minimum green;
4. reports the actual phases to `/controller/signal-states`.

The backend treats SUMO vehicles as observations with a source tag, never as registered
vehicles. The mobile app does not know SUMO exists.

## Demo / simulation mode (Phase 9)

When `DEMO_MODE=true`, a manager can start a simulated fleet from the app. The fleet includes
one ambulance, which is optional. Simulated vehicles:
- are real `vehicles` rows with `is_simulated=true`, `SIM-xxxx` codes and a disabled system
  owner account;
- follow routes over the configured intersection graph with car-following and signal
  obedience;
- stop at virtual signals that execute the engine's decisions, so adaptive control visibly
  changes queues;
- go through the same validation and ingest service, with source `SIMULATOR`.

The manager app has a "Include simulated data" switch, and every list shows a SIM badge. Real
and simulated data are never mixed without that label.

## App modes: Hardware Prototype and Software System

The mobile app opens with a mode choice, made before any login:
- **Software System** is everything above: login, the driver and manager apps, the backend and
  the traffic engine.
- **Hardware Prototype** is a separate, read-only monitor for one physical intersection driven
  by an ESP32. The phone joins the controller's Wi-Fi (STMS-RSU, no internet) and listens to its
  WebSocket (`ws://192.168.4.1:81/`, protocol v2 JSON frames). The app sends nothing to the
  controller, and the backend is not involved.

The code is split by mode: `mobile/lib/hardware/` (Hardware), `mobile/lib/mode/` (the choice),
and the rest of `mobile/lib/` (Software). Hardware mode never builds the software app, so it
makes no login or server requests. On Android it binds its connection to the Wi-Fi network so
traffic does not go out over mobile data.

The countdown is anchored to the controller's `remaining_ms` on every frame and freezes when
data stops (STALE after 1.5 s, or OFFLINE). Details, the simulator, the test server and the
platform settings are in `docs/HARDWARE_MODE.md`.

## J. Project structure

```text
Smart-Traffic-Management-App/
├── backend/                  FastAPI service
│   ├── app/
│   │   ├── api/v1/           HTTP + WebSocket routes (thin)
│   │   ├── core/             config, security, errors, rate limits, logging, units
│   │   ├── db/               engine/session, base classes, portable column types
│   │   ├── models/           SQLAlchemy tables
│   │   ├── schemas/          request/response models (camelCase, unknown fields rejected)
│   │   ├── repositories/     query helpers
│   │   ├── services/         business rules (telemetry, emergency, traffic, signals, demo…)
│   │   ├── realtime/         WebSocket hub
│   │   └── runner.py         periodic engine cycle + housekeeping
│   ├── alembic/versions/     migrations (committed)
│   ├── scripts/              create_user, seed_intersections, export_research_dataset
│   └── tests/                pytest (SQLite per test, no Docker needed)
├── traffic_engine/           pure-Python engine (no web/DB): geo, mapping, aggregation,
│   ├── src/traffic_engine/   network state, controllers, demo fleet simulation
│   └── tests/
├── sumo_bridge/              TraCI ↔ backend bridge + sample 4-junction corridor network
├── mobile/                   Flutter app (Android APK; manager dashboard also builds for web)
├── infra/                    docker-compose for PostgreSQL/PostGIS
├── docs/                     architecture, API, security & privacy, testing, setup, ADRs
└── .github/workflows/        CI: backend + engine tests, Flutter analyze/test, APK build
```

## K. Development roadmap

| Phase | Scope | Status |
|---|---|---|
| 1 | Architecture and technology selection | Done |
| 2 | Backend foundation: auth, roles, vehicles, devices, intersections, controller keys | Done |
| 3 | Driver app: login/registration, vehicle ID, GPS, telemetry, tracking, offline queue | Done |
| 4 | Manager app: dashboard, vehicles, live telemetry, map, intersections | Done |
| 5 | Emergency: authorisation review, emergency mode, events, notifications, map markers | Done |
| 6 | Traffic analysis: mapping, aggregation, congestion, history | Done |
| 7 | Adaptive interface: traffic state, controllers, signal plans, decisions, states, coordination | Done |
| 8 | SUMO bridge | Done (requires a local SUMO install to run) |
| 9 | Testing with simulated fleet across intersections | Done |
| 10 | Polish: errors, logging, security, docs, CI APK build | Done |

Known prototype limits are listed in `README.md`. The main ones: a single backend process
(the WebSocket hub is in-memory), advisory-only signal control, and a penetration-rate
assumption behind every estimated count.
