# Security and privacy

This is a final-year prototype. The measures below are implemented and tested; the "Before a real
deployment" list at the end names what is still required before real public use.

## What is collected, and why

| Data | From | Why | Who can see it |
|---|---|---|---|
| Name, email, password hash (argon2id), optional phone | Registration | Login, account recovery | The user; admins |
| Vehicle type, display name, optional registration number | Driver | Identify the vehicle to its owner; emergency authorization | Owner and admins. Managers see only the Vehicle ID (`VH-0012`), type and status. |
| Installation id (random per app install) | App | Bind a phone to a vehicle, one active tracker per vehicle | Owner, admins |
| GPS telemetry: time, position, accuracy, speed, heading, altitude, mock-location flag | App, only while the driver has pressed **Start tracking** | Traffic analysis | Managers (live map, vehicle track); the owner sees their own trips |
| Emergency authorizations and events | Driver request / manager decision | Audit of every emergency activation | Managers, the owner |
| SUMO / sensor observations | Machine clients | Traffic analysis in simulation | Kept in memory for 10 s only; never stored per vehicle |

Not collected: contacts, background location when tracking is off, device identifiers such as IMEI
or advertising id, photos, or anything from other apps. The app requests foreground location only
(a persistent notification is shown while tracking); it does not request background location.

## Retention

Applied automatically by the backend's periodic retention job (`app/services/runner.py`):

| Data | Kept for | Setting |
|---|---|---|
| Raw phone telemetry | 30 days | `TELEMETRY_RETENTION_DAYS` |
| Simulated (demo) telemetry | 24 hours | `SIMULATED_TELEMETRY_RETENTION_HOURS` |
| Reported signal states | 30 days | fixed |
| Signal decisions | 90 days | fixed |
| Aggregated traffic metrics (per intersection, no vehicle ids) | 1 year | fixed |
| Trips (sessions: start/end, distance, packet counts), emergency events | until the account is deleted | audit |

On the phone, packets waiting for upload are kept in the app's private database and deleted once the
server has accepted or rejected them, when they are older than the 10-minute backfill window, or when
the queue exceeds its size cap.

## Anonymised research export

`backend/scripts/export_research_dataset.py` writes a CSV for analysis or sharing:
vehicle ids are replaced by pseudonyms that change on every export, owner identity, registration
numbers, device and session ids are never read, timestamps and coordinates are rounded (4 decimals
≈ 11 m), short trips are dropped, and simulated vehicles are excluded unless requested. Share only
such exports, never a database dump.

## Access control

- Three roles: `END_USER`, `MANAGER`, `ADMIN`. The role is read from the database for every request;
  a role sent by the app is never trusted. Managers are created only by an admin.
- Drivers can reach only their own vehicles; another user's vehicle id answers 404, not 403, so ids
  cannot be probed.
- Machine clients (Raspberry Pi, SUMO bridge) use per-client API keys scoped to named intersections.
  Only the SHA-256 hash of a key is stored; keys can be revoked. Their data source (SUMO, CAMERA, ...)
  comes from the key, not the request body.
- Emergency mode is an authorized feature: only an emergency vehicle type with a manager-approved,
  unexpired authorization can start it, the app requires press-and-hold plus confirmation, every
  activation is logged, it ends automatically when no telemetry arrives for 2 minutes or after
  1 hour, and a manager can end it or revoke the authorization at any time.
- Suspending a vehicle ends its tracking session and any emergency; disabling a user revokes all
  their refresh tokens.

## Authentication and sessions

- Passwords: argon2id; minimum length and character rules enforced on the server.
- Access tokens: JWT (HS256), 15 minutes, signed with `JWT_SECRET` from the environment.
- Refresh tokens: random, stored hashed, 30 days, rotated on every use. Presenting an already-used
  refresh token revokes the whole session family (token theft detection).
- Password reset: single-use hashed tokens, 30 minutes; the response never reveals whether an email
  exists. In production the backend refuses to start without SMTP, so reset links never go to logs.
- The app keeps the refresh token in Android Keystore-backed storage (`flutter_secure_storage`) and the
  access token only in memory. The live WebSocket authenticates with its first message, never with a
  token in the URL.

## Input validation

All client data is validated on the server (pydantic schemas plus service rules): types and ranges,
no NaN/Infinity, batch size limits, per-packet telemetry plausibility (coordinates, accuracy, speed,
timestamps, sequence, jumps), and signal plans (minimum green, yellow and all-red limits). Errors never
echo submitted values. Rate limits protect login, registration, password reset, telemetry and
controller endpoints (see `docs/API.md`).

## Secrets and configuration

No credentials or API keys are in the source code. Secrets come from environment variables
(`backend/.env`, `infra/.env`, both git-ignored); `.env.example` files contain placeholders only.
The Android release keystore and `key.properties` are git-ignored. In production the backend
refuses to start with `DEMO_MODE=true` or a wildcard CORS origin.

## Traffic-signal safety

Signal timing produced by this system is **advisory and for simulation/prototype use**. Decisions
expire after 15 s; actuators (SUMO bridge, Raspberry Pi display) must keep minimum green, yellow and
all-red times and fall back to their local fixed plan without a valid decision. Nothing in this
project is certified to control real traffic signals.

## Threats considered

| Threat | Mitigation |
|---|---|
| Fake or replayed GPS | Per-packet plausibility checks, sequence numbers, mock-location flag (excluded from metrics), stale/future timestamp rejection |
| Unauthorised emergency priority | Server-side authorization, manager approval, audit log, automatic expiry |
| Stolen phone / token | Short access tokens, rotating refresh tokens with reuse detection, logout revokes, admin can disable account |
| Brute-force login | Rate limits, argon2id |
| Manager over-reach | Managers see Vehicle IDs, not owner identity or registration numbers |
| Database leak | Hashed passwords, refresh tokens, reset tokens and controller keys; 30-day telemetry retention |
| Rogue controller | Scoped, revocable keys; decisions advisory; actuators enforce safety timing locally |

## Before a real deployment

- HTTPS only (reverse proxy or tunnel); remove the app's cleartext-traffic allowance
  (`mobile/android/app/src/main/res/xml/network_security_config.xml`).
- A least-privilege database role instead of the Docker superuser; encrypted backups.
- Email verification and account deletion/export flows; a privacy notice and consent screen.
- Review by the relevant traffic authority before any connection to physical signals.
