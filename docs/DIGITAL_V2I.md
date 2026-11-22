# Digital V2I: the firmware v3 intersection on phones

Digital V2I is the app's third mode. It runs the V2I firmware v3 (`docs/firmware-v3`) on
phones instead of ESP32 boards:

| Hardware (firmware v3) | Digital V2I |
|---|---|
| `intersection_esp32.ino` on an ESP32 | an **ADMIN or MANAGER** phone runs the same controller, ported to Dart (`mobile/packages/v2i_core`) |
| `vehicle_node.ino` on ESP32 / ESP8266 boards | **driver** phones run the same vehicle unit |
| Wi-Fi AP + UDP 4210 / HTTP `/api/vehicle` | a transport: the server relay (cloud), the intersection phone's own LAN server, or a bridge to the real ESP32 |
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
   - **My trip**: one of the driver's trips recorded in the Software System, **one recorded point
     per 500 ms, looping**, exactly like the firmware's TEST_SOURCE 1 with `REPLAY[]`. No `tl`
     (the trip's arm is not known); a recorded heading is sent only where the recorded speed was
     at least 1 m/s. The screen says how close the trip comes to the junction centre.
4. **Start.** The phone sends a `pos` packet every 500 ms and shows only what the ACK says: the
   signal of its lane, counted down locally between ACKs, the lane and state the intersection
   decided, the mode, PRIORITY. With no ACK for 3 s it shows RED. The **Basis** line is the same
   lane decision run on the phone for display only. Emergency vehicles also show the time from
   the first lane assignment to green.

## Test injector (demo with one phone)

On the intersection screen, **Test injector** adds virtual vehicles that run the firmware's
vehicle simulation inside the intersection phone and obey its ACKs like the ESP vehicles:
- the six firmware presets as one-tap chips (ids 101–104, 201, 202 as on the boards; presets 5
  and 6 wait 30 s / 70 s out of range, then drive in as emergency vehicles);
- a custom vehicle: arm, queue slot, normal or emergency, delay (start 100 m / 30 km/h, or
  140 m / 50 km/h for emergency, as in the presets), id 501–999.

They show "inject" as their device in the vehicle table and in exports. Tap a chip again (or ✕)
to switch one off: it stops sending and the controller removes it 3 s later, as in README case 4.

## Recording, metrics and export

Every intersection session records, from the moment it starts:
- the **full controller log** (every Serial-Monitor line, not only the last 5000 on screen),
- a **snapshot every second** (mode, requested mode, phase, current lane, each lane's signal,
  time left, queued, approaching, Qw, vehicles, congestion, emergency lane, priority),
- **every accepted packet** as the intersection decided it (id, type, device, lane, state,
  distance, speed, packet and loss counters),
- every **RTT** a vehicle phone reports.

**Metrics** (header button on the intersection screen) are computed from these records only:

| Metric | How |
|---|---|
| Wait (average, max; per vehicle) | from the packet where a vehicle becomes QUEUED on a lane that is not green, to that lane's next `[SIG ] lane X GREEN` line; counted only if the vehicle is still waiting on that lane then. Resolution: the 500 ms packet interval. |
| Throughput per lane | entries into the junction box (CROSSING) from each lane; veh/h = count / recorded time |
| Cycle length over time | green start → next green start of the same lane, from the `[SIG]` lines; the planned C0 of every `[PLAN]` line is exported too |
| Emergency detection → green | the intersection's `[PRIO] lane X GREEN for emergency id=…, x s after its request` lines (the vehicle phone shows its own measurement) |
| Packet loss | the controller's counters (gaps in `seq`) per vehicle, added up across removals |
| RTT | samples measured on the vehicle phones; median and p95 (injected vehicles are not counted: no network) |

**Fixed vs Adaptive** (from the metrics screen) runs the injected vehicles (or the six presets
when none are injected) twice with the same random seed, once with the mode forced FIXED and once
in AUTO, headless on a fake clock in a background isolate, and shows both side by side. The
speed is measured and shown ("digital simulation, N× real time").

**Export CSV + raw log** writes four files (and the comparison writes a fifth):

| File | Content |
|---|---|
| `v2i_<session>_<date>_events.log` | time since start, phone time, and each controller line unchanged |
| `…_snapshots.csv` | one row per second |
| `…_vehicles.csv` | one row per accepted packet |
| `…_metrics.csv` | metric, scope, value, unit, how it was obtained |
| `…_fixed_vs_adaptive.csv` | the comparison, both runs side by side |

Every file starts with `#` lines: **"digital simulation, measured on <device> on <date>"**, the
session, the transport, and for the comparison the scenario and the measured speed-up (read with
`pandas.read_csv(path, comment='#')`). On Android the files go to **Downloads/DigitalV2I**
(MediaStore; on Android 9 and older, the app's own Downloads folder); for a cloud session a copy is
also stored on the server (`/api/v1/v2i/sessions/{id}/exports`, host and admins only).

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

## LAN and hardware bridge (LanTransport, HardwareBridgeTransport)

**LAN on the intersection phone.** When the host taps **Run the intersection**, the sheet
offers the **Cloud relay** (default), **LAN on this phone**, or both at once. With LAN on, the
phone serves what the ESP32 serves, on its Wi-Fi or hotspot:

| ESP32 (firmware v3) | Intersection phone |
|---|---|
| `GET /api/state` on port 80 | `GET http://<phone>:8080/api/state` (built on request, as in the firmware) |
| `GET /api/mode?m=auto\|fixed\|adaptive` | the same on 8080; logged `(from web /api/mode)`, same reply JSON |
| `POST /api/vehicle` → ACK, or 400 `{"error":"bad packet"}` | the same on 8080 |
| WebSocket `ws://192.168.4.1:81/`, state every 500 ms, mode commands | `ws://<phone>:8081/`, the same; `[APP ] WebSocket client n connected` and `unknown WebSocket command` lines as in the firmware |
| UDP 4210, ACK back to the sender | the same (256-byte buffer) |

Android apps cannot open ports below 1024, hence 8080 / 8081 instead of 80 / 81. A phone hotspot
is usually 192.168.43.1 or 10.x.x.x, not 192.168.4.1: the intersection screen's **LAN** card lists
the phone's addresses. **Hardware mode** on another phone shows the digital intersection with the
four-lane dashboard: settings → controller = that address, port = 8081.

On a LAN no server checks accounts, so emergency packets (`"ty"` not 0) are **refused** unless the
host switches on **Accept emergency packets over the LAN** (which is how the ESP32 prototype
behaves: anyone on its Wi-Fi may send them). A refused packet gets 400 over HTTP and no reply over
UDP, and is counted on the LAN card.

**Vehicles over the LAN.** In the drive setup of a joined session, **Connection → LAN** and the
intersection phone's address (e.g. `192.168.43.1:8080`). The phone POSTs each packet to
`/api/vehicle` and shows the ACK from the response; it keeps sending every 500 ms whether or not
the last request was answered, like a UDP beacon, and shows RED after 3 s without an ACK.

**Hardware bridge (the real ESP32).** On the driver home, **Drive at the ESP32 junction**: join the
Wi-Fi `V2I-Junction-01` (password `v2i12345`), then the phone POSTs its packets to
`http://192.168.4.1/api/vehicle` every 500 ms and shows the ESP32's ACK, so phones and ESP vehicles
share one physical junction. The phone keeps its traffic on that Wi-Fi (it has no internet), as
Hardware mode does. It uses the account's V2I id (1001+), which cannot collide with the board
presets (101–202). The ESP32 cannot check accounts: the phone only sends `"ty":1` if an admin
approved it.

RTT is measured the same way on every transport (send → ACK by `seq`): over the LAN test on one
machine (localhost) the samples were 6–9 ms; on real Wi-Fi it will be higher.

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
- Saving to Downloads (MediaStore) and the device name: written for Android, tested only through
  a fake of the Android side.
- LAN: tested with real sockets on one machine (HTTP, WebSocket, UDP, a vehicle over HTTP, and
  Hardware mode's live source showing the digital intersection), not between two phones on a
  hotspot; whether a given phone's hotspot lets clients reach ports 8080/8081 depends on the phone.
- Hardware bridge: the HTTP protocol is the one tested against the LAN server (which mirrors the
  ESP32's), but not against the physical ESP32.
