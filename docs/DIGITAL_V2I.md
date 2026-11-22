# Digital V2I: the firmware v3 intersection on phones

Digital V2I is the app's third mode. It runs the V2I firmware v3 (`docs/firmware-v3`) on
phones instead of ESP32 boards:

| Hardware (firmware v3) | Digital V2I |
|---|---|
| `intersection_esp32.ino` on an ESP32 | an **ADMIN or MANAGER** phone runs the same controller, ported to Dart (`mobile/packages/v2i_core`) |
| `vehicle_node.ino` on ESP32 / ESP8266 boards | **driver** phones run the same vehicle unit |
| Wi-Fi AP + UDP 4210 / HTTP `/api/vehicle` | a transport: the server relay (cloud), later LAN or a bridge to the real ESP32 |
| TM1637 MM:SS displays, LEDs | the junction view with one head and one MM:SS display per lane |
| Serial Monitor | the controller log, line for line the firmware's text |

The port keeps the firmware's formulas, constants, thresholds, timings, state names, reason
strings, log tags, packet and ACK text, and the state JSON (`"v":2` first, same keys and order).
It is checked by 76 unit tests (`mobile/packages/v2i_core/test`), including the README's test
cases and the exact Webster `[PLAN]` line. Firmware behaviour that looks odd is kept and listed
under "Firmware behaviour kept as is".

## Who is what (decided by the server)

The role is never chosen on the phone:
- **ADMIN / MANAGER** accounts can host a digital intersection: the host's phone is the
  intersection, the only authority for the signals.
- **END_USER** (driver) accounts join a session with its code: the phone is a vehicle. The
  server gives each account a V2I vehicle id (1001–65535, assigned once; 101–202 stay reserved for
  the hardware presets).
- **Emergency vehicles:** an admin sets it per account, or approves a driver's request. Only
  then may that phone send `"ty":1`; the server refuses `ty:1` from any other account. A change
  applies at once to an open connection (the drive ends and asks to start again).

## How to run it

Both phones need the server (Software System server address) and an account.

**Intersection phone (ADMIN / MANAGER)**
1. Mode selection → **Digital V2I** → sign in.
2. **New digital intersection**: a name and the junction centre. The default centre is the
   firmware's test-data origin (31.500000, 74.300000); **Use my location** or **Pick on the
   map** set a real one. Arms N, E, S, W go out from the centre; vehicles count up to 150 m.
3. **Create and run.** The screen shows the join code (tap **Code …** for a large code and a QR
   code), the relay state, the junction, the current phase, the lanes table, the Webster plan, the
   vehicle table with each vehicle's round-trip time, and the controller log.
4. **Mode**: Auto / Fixed / Adaptive are the firmware's `o` / `f` / `a` commands. A change applies
   at the next lane decision; a running green is never cut. **[RX] log** is the `r` command.
5. Keep the screen open: it stays awake, and if the app goes to the background the screen and
   the log say for how long (Android may slow the loop while the app is hidden).
6. Leaving the screen stops the controller (vehicles see RED 3 s later). **Close session** on the
   home screen ends the session and the code.

**Vehicle phone (driver)**
1. Mode selection → **Digital V2I** → sign in. The home screen shows the V2I vehicle id and the
   emergency status (with **Request emergency-vehicle status**).
2. Enter the **join code** → **Join**.
3. Choose the position source:
   - **Simulated**: the firmware's motion simulation on an arm (queue slot, start distance,
     speed). It obeys the ACK: brakes for red, never passes the stop line on red, restarts the trip
     15 s after leaving. It sends `tl` (the arm), like the firmware's test data.
   - **Live GPS**: the phone's position, speed and heading (heading left out below 1 m/s, where
     phones report noise). No `tl`. Location permission is needed.
   - **My trip**: one of the driver's trips recorded in the Software System, sent at its recorded
     times. Between two recorded points the last one is repeated; nothing is interpolated. The
     screen says how close the trip comes to the junction centre.
4. **Start.** The phone sends a `pos` packet every 500 ms and shows only what the ACK says: the
   signal of its lane, counted down locally between ACKs, the lane and state the intersection
   decided, the mode, PRIORITY. With no ACK for 3 s it shows RED. The **Basis** line is the same
   lane decision run on the phone for display only. Emergency vehicles also show the time from
   the first lane assignment to green.

## Cloud relay (CloudRelayTransport)

`wss://<server>/api/v1/v2i/ws`. The access token goes in the first message, never in the URL:

```
client -> {"type":"auth","accessToken":"…","sessionId":"…"}
server -> {"k":"hello","as":"intersection"|"vehicle","vid":1001,"emergency":false,"session":{…}}
vehicle      -> {"k":"pos","raw":"{\"t\":\"pos\",\"id\":1001,…}"}      (every 500 ms)
intersection <- {"k":"pos","vid":1001,"raw":"…"}                        (unchanged text)
intersection -> {"k":"ack","to":1001,"raw":"{\"t\":\"ack\",…}"}
vehicle      <- {"k":"ack","raw":"…"}
vehicle      -> {"k":"rtt","ms":87}   intersection <- {"k":"rtt","vid":1001,"ms":87}
intersection -> {"k":"state","raw":"{\"v\":2,\"t\":\"state\",…}"}      (every 500 ms, kept for the host)
```

The server checks every packet before it passes: shorter than 200 B (`V2I_MAX_PACKET`), the
account's own vehicle id, `ty:1` only when authorised, value ranges (lat/lon, spd 0–400 km/h, hdg
0–359, seq, `hw` ≤ 11 characters, `tl` N/E/S/W, rssi), no unknown fields, at most 4 packets/s per
vehicle. It forwards the packet text unchanged, so the intersection parses exactly what the vehicle
sent, as the ESP32 would. ACKs go only to their vehicle; the state JSON goes to the host's
`GET /api/v1/v2i/sessions/{id}/state`, never to vehicles. Close codes: 4401 sign in again,
4403 not part of the session, 4404 no open session, 4409 opened elsewhere, 4410 session closed.
The phones reconnect every 2 s and refresh the token every 10 minutes.

**Round-trip time** is measured on the vehicle for every packet (send → its ACK, by `seq`), shown
on the vehicle and reported to the intersection's vehicle table. It includes the server hop and
both phones' network; it is a measurement, not a setting.

## Firmware behaviour kept as is

Reported, not changed (see the Phase 1 notes):
- "not on any arm" cannot happen with the firmware thresholds (45° inclusive, arms 90° apart).
- An emergency request on a lane that is already green holds it up to 25 s from the request, so
  that green can last longer than its plan.
- The README's "(121 B)" packet was measured with the board name `ESP32` (the printed line says
  `ESP32-S3`, 3 bytes more).
- `[MISMATCH]` is not logged for a vehicle seen in the first 2 s after start.
- The vehicle's own "detection → green" is a multiple of its 500 ms beacon period.

## What has not been verified

- Two real phones over the deployed server: the relay is tested with real WebSockets in the
  backend tests and the phones' side with a fake socket and the in-app transport, but not
  end-to-end on devices.
- Live GPS on a phone driving through a junction.
- Background behaviour on Android (timers while the app is hidden).
