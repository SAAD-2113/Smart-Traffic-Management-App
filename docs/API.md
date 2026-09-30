# API reference

Base URL: `http://<server>:8000/api/v1`. Interactive documentation with every request and response
schema: `http://<server>:8000/docs` (Swagger UI) or `/redoc`; the machine-readable spec is `/openapi.json`.

JSON field names are camelCase. Times are ISO 8601 with a timezone (UTC is returned). Units are SI:
metres, seconds, metres per second (the apps convert to km/h for display).

## Authentication

| Client | How it authenticates |
|---|---|
| Driver and manager apps | `Authorization: Bearer <accessToken>` from `POST /auth/login`. Access tokens are JWTs valid for 15 minutes. |
| Token renewal | `POST /auth/refresh` with the refresh token. Refresh tokens are opaque, stored hashed, valid 30 days and **rotated** on every use; reusing an old one revokes the whole family. |
| Raspberry Pi / SUMO bridge / other machine clients | `X-Controller-Key: stc_...`, created by an admin and scoped to specific intersections. Only its hash is stored. |
| Live dashboard WebSocket | First message `{"type":"auth","accessToken":"..."}` (never in the URL). |

Roles come from the database record of the authenticated user, never from the client.
`END_USER` = driver/vehicle owner, `MANAGER` = traffic manager, `ADMIN` = manager plus user and key
administration.

## Errors

Every error has the same envelope:

```json
{"error": {"code": "VALIDATION_ERROR", "message": "The request contains invalid data.",
           "details": [{"field": "email", "issue": "value_error", "message": "..."}],
           "requestId": "3f2c..."}}
```

| HTTP | Typical `code` |
|---|---|
| 400 | `BAD_REQUEST`, `INVALID_RESET_TOKEN`, `INVALID_CURRENT_PASSWORD`, `INSTALLATION_ID_REQUIRED` |
| 401 | `NOT_AUTHENTICATED`, `INVALID_CREDENTIALS`, `INVALID_TOKEN`, `TOKEN_EXPIRED`, `REFRESH_TOKEN_REUSED`, `INVALID_CONTROLLER_KEY` |
| 403 | `FORBIDDEN`, `ACCOUNT_DISABLED`, `EMERGENCY_NOT_AUTHORIZED`, `NOT_EMERGENCY_VEHICLE`, `OUT_OF_SCOPE`, `DEMO_DISABLED` |
| 404 | `NOT_FOUND` (also returned for other users' resources, so ids cannot be probed) |
| 409 | `SESSION_NOT_ACTIVE`, `TRACKING_NOT_ACTIVE`, `VEHICLE_NOT_ACTIVE`, `VEHICLE_LIMIT_REACHED`, `EMAIL_ALREADY_REGISTERED`, `AUTHORIZATION_PENDING`, `DEMO_RUNNING`, ... |
| 422 | `VALIDATION_ERROR` (submitted values are not echoed back), `CONFIRMATION_REQUIRED`, `INVALID_SIGNAL_PLAN`, `CLOCK_SKEW` |
| 429 | `RATE_LIMITED` |
| 500 | `INTERNAL_ERROR` (details only in the server log, keyed by `requestId`) |

## Rate limits (per client IP)

| Endpoint | Limit |
|---|---|
| `POST /auth/register` | 3 / hour |
| `POST /auth/login` | 5 / minute |
| `POST /auth/refresh` | 30 / minute |
| `POST /auth/password/forgot` · `/reset` | 5 / hour · 10 / hour |
| `POST /vehicles/{id}/telemetry` | 240 / minute |
| `POST /vehicles/{id}/emergency/start` | 10 / minute |
| `POST /vehicles/{id}/emergency/authorization-request` | 5 / hour |
| `GET /controller/decisions` | 120 / minute |
| `POST /controller/signal-states` · `/controller/observations` | 240 / minute |

Behind a reverse proxy or tunnel, start uvicorn with `--proxy-headers` so the real client IP is used.

## Endpoints

### Public and account

| Method | Path | Notes |
|---|---|---|
| GET | `/health` | Database check and server time. |
| POST | `/auth/register` | Creates an `END_USER`. Managers are created by an admin. |
| POST | `/auth/login` | Returns `accessToken`, `refreshToken`, `user`. |
| POST | `/auth/refresh` · `/auth/logout` | Rotate / revoke a refresh token. |
| POST | `/auth/password/forgot` · `/auth/password/reset` | Reset link by email (printed to the console in development). Always answers 202 so emails cannot be probed. |
| POST | `/auth/password/change` | Logged in; signs out every other session. |
| GET / PATCH | `/me` | Own profile (name, phone). |
| GET | `/me/vehicles` | Own vehicles. |

### Driver (role `END_USER`, own vehicles only)

| Method | Path | Notes |
|---|---|---|
| POST | `/vehicles` | Register a vehicle; the server assigns the Vehicle ID (`VH-0001`, `EV-0001` for emergency types). |
| GET | `/vehicles/{id}` | |
| POST / GET / DELETE | `/vehicles/{id}/devices[/{deviceId}]` | Bind this phone (installation id) to the vehicle. |
| POST | `/vehicles/{id}/tracking/start` | Header `X-Installation-Id`. Opens a tracking session; one active session per vehicle. |
| POST | `/vehicles/{id}/tracking/stop` | Body `{"sessionId": ...}` optional. |
| GET | `/vehicles/{id}/tracking/sessions` | Trip history (distance, duration, packet counts). |
| POST | `/vehicles/{id}/telemetry` | Batched telemetry, see below. |
| GET | `/vehicles/{id}/telemetry/latest` | What the server last accepted for this vehicle. |
| GET | `/vehicles/{id}/emergency` | Authorization status and active emergency, if any. |
| POST | `/vehicles/{id}/emergency/authorization-request` | Ask a manager to authorize this vehicle (ambulance, fire, police). |
| POST | `/vehicles/{id}/emergency/start` · `/stop` | Start requires `{"confirm": true}` and an **approved** authorization; otherwise 403. |

#### Telemetry packet (version 1)

```http
POST /api/v1/vehicles/{vehicleId}/telemetry
Authorization: Bearer <accessToken>

{
  "sessionId": "0b8e...",
  "packets": [
    {"seq": 41, "recordedAt": "2026-09-30T10:15:02.120Z", "lat": 31.52041, "lon": 74.33712,
     "accuracyM": 6.5, "speedMps": 11.2, "speedAccuracyMps": 0.8, "speedSource": "GPS",
     "headingDeg": 92.0, "altitudeM": 214.0, "emergency": false, "mocked": false}
  ]
}
```

- 1 to 500 packets per request (the app uploads its queue every 2 s, up to 100 packets at a time).
- The Vehicle ID and owner come from the URL and the access token, never from the packet.
- `emergency` in a packet is only a hint: emergency status is taken from the server-side active,
  authorized emergency event.
- Each packet is validated separately; the response lists every packet as `ACCEPTED` (with `live`
  and `usable` flags) or `REJECTED` with a reason, so one bad packet never blocks an offline backlog:

| Reason | Meaning |
|---|---|
| `INVALID_COORDINATES` | Outside the valid range, or exactly 0,0. |
| `INVALID_ACCURACY` · `LOW_ACCURACY` | Accuracy ≤ 0, or worse than the configured maximum. |
| `INVALID_SPEED` · `UNREALISTIC_SPEED` | Negative, or above the configured maximum speed. |
| `INVALID_HEADING` · `INVALID_ALTITUDE` | Heading outside 0-360°, altitude outside -500..9000 m. |
| `FUTURE_TIMESTAMP` · `STALE_TIMESTAMP` | Clock too far ahead, or older than the 10-minute backfill window. |
| `DUPLICATE_OR_OUT_OF_ORDER` | `seq` or `recordedAt` not after the last accepted packet. |
| `TOO_FREQUENT` | Packets closer together than the minimum interval. |
| `IMPLAUSIBLE_JUMP` | Position jump faster than physically possible (re-anchored after repeated jumps). |

A packet is **live** when recorded within the last 15 s (used for real-time traffic) and **usable**
when its accuracy is at most 50 m and it is not a mock location. Older accepted packets are stored as
history only. See `docs/ARCHITECTURE.md` for the complete rules.

### Manager (roles `MANAGER`, `ADMIN`)

| Method | Path | Notes |
|---|---|---|
| GET | `/manager/vehicles[/{id}]` | Registered vehicles: operational fields only, no owner identity or registration number. |
| PATCH | `/manager/vehicles/{id}/status` | Suspend / reactivate. Suspension ends its tracking session and emergency. |
| GET | `/manager/live/vehicles[/{id}]` | Live positions (last 15 s) with freshness and GPS quality. |
| GET | `/manager/vehicles/{id}/telemetry` | Track of one vehicle over a time range. |
| GET | `/manager/emergency/authorizations` | Pending/approved/rejected emergency authorizations. |
| POST | `/manager/emergency/authorizations/{id}/approve` · `/reject` | |
| POST | `/manager/vehicles/{id}/emergency-authorization/revoke` | Also ends an active emergency. |
| GET | `/manager/emergency/events` · POST `/manager/emergency/events/{id}/end` | Emergency log; end one manually. |
| GET / POST / PATCH / DELETE | `/intersections[/{id}]` | DELETE deactivates (history is kept). |
| POST | `/intersections/{id}/approaches` · `/intersections/{id}/links` | Approach geometry and inter-intersection links. |
| GET | `/traffic/overview` | Dashboard figures (vehicles, speeds, congestion, system status). |
| GET | `/traffic/intersections[/{id}]` | Per intersection and per approach: observed, calculated and estimated metrics, data quality, emergencies, signal state and the current decision. |
| GET | `/traffic/intersections/{id}/history` · `/traffic/history` | Time series (`hours`, `bucketS`). |
| GET | `/emergency/active` | Active emergencies with position and nearest intersection. |
| GET | `/signals/overview` | Plan, decision and reported state for every intersection. |
| GET / PUT | `/intersections/{id}/signal-plan` | Phase plan (min/max/fixed green, yellow, all-red). Validated for safety limits. |
| GET | `/intersections/{id}/signal-decisions` | Decision log. |
| GET | `/demo/status` · POST `/demo/start` · `/demo/stop` | Simulated fleet. Only when `DEMO_MODE=true`; refused in production. |

### Admin (role `ADMIN`)

| Method | Path | Notes |
|---|---|---|
| POST | `/admin/managers` | Create a manager account. |
| PATCH | `/admin/users/{id}/status` | Disable / enable an account (revokes its refresh tokens). |
| GET | `/admin/vehicles/{id}` | Full vehicle record including registration number and owner id. |
| GET / POST | `/admin/controller-clients` | Create a controller key (`RASPBERRY_PI`, `SUMO_BRIDGE`, `CAMERA`, `OTHER`), scoped to intersections. The key is returned once. |
| POST | `/admin/controller-clients/{id}/revoke` | |

### Controller clients (header `X-Controller-Key`)

| Method | Path | Notes |
|---|---|---|
| GET | `/controller/ping` | Key check; returns the intersections in scope. |
| GET | `/controller/decisions` | Current advisory decision (with `validUntil`) and signal plan (with `approachBearings`) for each intersection in scope. |
| GET | `/controller/traffic-state` | Traffic metrics for the intersections in scope. |
| POST | `/controller/signal-states` | Report the actual light state (phase, colour, mode, remaining time). |
| POST | `/controller/observations` | Vehicles seen by a simulator or sensor (`vehicles[]`) and detector counts (`counts[]`). The source is taken from the key kind (SUMO, CAMERA, ...), never from the body. |

Decisions are **advisory**: a controller applies one only while it is valid and never shortens
minimum green, yellow or all-red. Without a valid decision it runs its local fixed plan.

## WebSocket: `/api/v1/live/ws` (roles `MANAGER`, `ADMIN`)

1. Connect, then send `{"type": "auth", "accessToken": "..."}` within 10 s.
2. The server answers `{"type": "hello", "serverTime": ..., "role": ...}` and the latest snapshot.
3. After every engine cycle (about every 2 s): `{"type": "snapshot", ...}` with the overview,
   intersections and live vehicles.
4. Emergency events as they happen: `{"type": "event", "event": "EMERGENCY_STARTED" | ...}`.
5. The client may send `{"type": "ping"}`; the server answers `{"type": "pong"}`.

The connection closes with code 4401 if authentication fails or the token expires (4403 for a non-manager); the app then
refreshes its token and reconnects, and falls back to polling the REST endpoints meanwhile.
