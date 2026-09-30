# ADR 0001: Raspberry Pi intersection controllers connect to the backend over the internet

Status: Accepted (Phase 2)

## Context
Each intersection has a Raspberry Pi signal controller. The Pis could either reach the
backend directly over the internet, or stay on the nRF24L01 radio link and relay through a
single gateway Pi. The team chose direct internet connectivity.

## Decision
1. Every Pi is a separate `controller_client` with its own API key, scoped to its own
   intersection(s). A key stolen from I2 cannot act on I3. Only the key's SHA-256 hash is
   stored; the key is shown once, at creation.
2. The Pi always opens the connection outward (HTTPS now, a WebSocket in Phase 7). No port
   forwarding or static IP is needed, so it works on a 4G SIM behind carrier NAT.
3. The Pi runs its own fixed-time plan and enforces its own minimum green, yellow and
   all-red times at all times. Backend decisions are advisory: the Pi applies one only if
   it is recent (not past its `validUntil`) and within local limits. If the connection is
   lost, the Pi falls back to its local fixed-time plan by itself.
4. The nRF24L01 radios are not needed for backend communication. They may remain as an
   optional local link between neighbouring intersections.

## Consequences
- Available now: `POST /admin/controller-clients` (create key), `GET /controller/ping`
  (the Pi checks its key, scope and internet path; updates `lastSeenAt`), and revocation.
- Phase 7 adds the controller WebSocket channel: decisions from server to Pi, actual signal
  state and heartbeats from Pi to server.
- A lost internet link degrades the intersection to fixed-time control, never to an unsafe state.
