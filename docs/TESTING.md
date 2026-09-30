# Testing

## Running the automated tests

```powershell
cd traffic_engine;  uv run --group dev pytest        # 42 tests, pure Python
cd backend;         uv run pytest                    # 98 tests, throwaway SQLite per test (no Docker needed)
cd mobile;          flutter analyze; flutter test    # 26 tests
```

CI (`.github/workflows/ci.yml`) runs all three suites, then builds the Android APK and the web
dashboard on every push.

## What is covered

| Area (spec) | Automated tests | Where |
|---|---|---|
| Authentication, token rotation and reuse detection, password reset | 13 | `backend/tests/test_auth.py` |
| Role-based access, owner-only data, manager-only and admin-only endpoints | 8 + checks in every suite | `test_permissions.py`, `*_are_manager_only` tests |
| Security helpers (hashing, JWT claims, key hashing) | 6 | `test_security.py` |
| Vehicle registration, Vehicle ID, device binding, suspension | 13 | `test_vehicles.py` |
| Telemetry validation: ranges, NaN, missing fields, batch size, timestamps (old/future/backfill), order, replay, frequency, GPS jumps and re-anchoring, mock location, poor accuracy | 15 | `test_telemetry.py` |
| Tracking sessions: bound device only, restart closes old session, trip statistics | in `test_telemetry.py` | |
| Emergency flow: normal vehicle refused, pending authorization refused, confirmation, full flow, revocation, manager end, stale expiry, re-request, expired authorization | 11 | `test_emergency.py` |
| Traffic processing: mapping to approach/core/departure/link, no data = UNKNOWN, single-probe scaling labelled low quality, waiting time, detector counts not scaled, congestion thresholds | 17 | `traffic_engine/tests/test_mapping.py`, `test_aggregation.py` |
| Multi-intersection: upstream arrivals, downstream gating, links with ETA | in `test_control.py`, `test_mapping.py` | |
| Signal control: plan validation (unsafe values rejected), fixed fallback with reason, demand-proportional within limits, emergency priority near / not far, decision expiry | 12 | `traffic_engine/tests/test_control.py`, `backend/tests/test_traffic.py` |
| Virtual signals: min green kept before priority, expired decision ignored | 3 | `test_simulation.py` |
| Controller clients: invalid key, scope, SUMO observations feed the engine, only SUMO may flag emergencies | 11 | `test_controller_clients.py`, `test_controller_io.py` |
| Live dashboard WebSocket: auth message required, end users refused, snapshots delivered | 3 | `test_live_ws.py` |
| Demo simulation: refused when disabled, runs through the real pipeline, API | 4 + 5 | `test_demo.py`, `traffic_engine/tests/test_simulation.py` |
| Mobile: packet builder (SI units, UTC, accuracy/interval filters, derived speed, unknown speed stays null) | 7 | `mobile/test/packet_builder_test.dart` |
| Mobile: offline queue, ordered delivery, backfill window, backoff, errors keep packets, closed session stops | 9 | `upload_policy_test.dart`, `tracking_controller_test.dart` |
| Mobile: validators, server address, unit conversion | 8 | `config_and_units_test.dart` |
| Mobile UI: hold-to-confirm, "no data" badge | 2 | `widget_smoke_test.dart` |

## End-to-end checks done during development

- **Demo pipeline:** backend with `DEMO_MODE=true`, the manager app (web build) driven in headless
  Chromium: login, dashboard, live map, intersections, signals, traffic analysis, history, demo start/stop,
  emergency approval.
- **SUMO:** `sumo_bridge/bridge.py` against the running backend (4-junction corridor, 260 simulated
  seconds): SUMO vehicles appear as source `SUMO` with HIGH data quality, adaptive decisions are served,
  the bridge reports light states (connected), and the SUMO ambulance is detected on the Eastbound
  approach with an ETA, producing EMERGENCY_PRIORITY decisions at I1 then I2 that the bridge applied.
- **APK:** checked statically (manifest, permissions, components, dex references, signature). It has
  not been installed on a physical phone in the build environment; do that first (below).

## Manual test plan on a phone

Run the backend on a PC (`--host 0.0.0.0`), phone on the same Wi-Fi, server address set in the app's
login screen (`http://<PC IP>:8000`).

| # | Test | Expected |
|---|---|---|
| 1 | Register, log in, close and reopen the app | Still logged in (refresh token), no password asked |
| 2 | Register a vehicle, start tracking, deny location permission | Clear message, tracking does not start |
| 3 | Allow permission, start tracking, walk/drive | Notification shown; Home shows GPS quality, speed, packets sent; the manager live map shows the vehicle within ~2 s |
| 4 | Turn off Wi-Fi/mobile data for 2 minutes while tracking, then back on | Queue count grows, then drains in order; manager track has no gap older than 10 min |
| 5 | Put the phone indoors (poor GPS) | GPS quality drops to Poor/No fix; manager view shows "low accuracy", metrics ignore the vehicle |
| 6 | Enable a mock-location app | Packets stored but flagged, excluded from traffic metrics |
| 7 | Normal vehicle: open Emergency | Not available; request authorization only for emergency types |
| 8 | Ambulance vehicle: request authorization; manager approves; hold the button | Emergency active; manager gets a notification; nearest intersection shows priority (advisory) |
| 9 | Manager revokes authorization (phone tracking) | The emergency banner on the phone clears within a few seconds |
| 10 | Stop tracking; drive past intersections | Nothing is sent (no background location) |
| 11 | Manager: suspend the vehicle | Driver's tracking stops with a message |
| 12 | Log out on the phone | Refresh token revoked; reopening asks for login |

## Field test with real vehicles (research)

1. Replace the placeholder I1-I4 coordinates with real intersections and approach bearings.
2. Record with a small number of phones; note the real traffic situation (count vehicles by hand or
   with a camera for 10-minute samples).
3. Compare the engine's observed and estimated counts and congestion level with the manual counts;
   the estimated values depend on the penetration rate, so report both.
4. Export with `scripts/export_research_dataset.py` for analysis; do not share raw database dumps.
