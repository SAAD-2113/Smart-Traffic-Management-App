# ADR 0002: Batched REST for telemetry, WebSocket for dashboards, HTTPS polling for controllers

Status: Accepted (Phase 3). Refines the "Phase 7 controller WebSocket" note in ADR 0001.

## Context
Three kinds of client exchange time-sensitive data with the backend:
phones (up to ~1 fix/s each), manager dashboards (need pushed updates), and machine clients
(Raspberry Pi controllers, the SUMO bridge) that need advisory decisions within a few seconds.
Candidates were REST, WebSockets, MQTT, Firebase and Supabase Realtime.

## Decision
1. **Phones → backend: HTTPS REST, batched.** `POST /vehicles/{id}/telemetry` takes up to 100
   packets and answers per packet. Uploads run every 2 s from a local queue. The same call
   carries the offline backlog when a connection comes back. Standard bearer auth, rate
   limiting and request logging all apply. Phones need no persistent connection, which saves
   battery and works on any mobile network.
2. **Backend → manager apps: WebSocket** (`/api/v1/live/ws`). The first message carries the
   access token; tokens never go in query strings, which end up in logs. The server pushes
   one snapshot per engine cycle (2 s) and emergency events immediately. REST endpoints
   return the same data for polling fallback and history.
3. **Machine clients: HTTPS polling (1-2 s), not a WebSocket.** Decisions are advisory and
   carry `validUntil`. A poll that is a second late is harmless, and a missed poll falls back
   to fixed time as ADR 0001 requires. Polling has no reconnect logic, works through every
   tunnel and proxy, and is trivial to implement on a Pi. A controller WebSocket can be added
   later behind the same service functions without changing the decision model.
4. **Not chosen:** MQTT (extra broker and per-device credentials, for little benefit at these
   rates); Firebase/Supabase Realtime (they would split the source of truth away from the
   server-side validation and the traffic engine).

## Consequences
- The backend runs as **one process**, because the WebSocket hub and the engine runner are
  in-memory. Scaling out would need Redis pub/sub for the hub and a leader lock for the
  runner (documented as future work).
- Controllers see a new decision up to one poll interval late. Decisions last 15 s, which
  is well above that.
