# V2I Smart Traffic Management – firmware v3 (AUTO fixed/adaptive)

```
V2I/
├── intersection_esp32/          <- open THIS folder's .ino for the ESP32 DevKit V1
│   ├── intersection_esp32.ino
│   └── v2i_common.h             (identical copy)
└── vehicle_node/                <- open THIS folder's .ino for every vehicle board
    ├── vehicle_node.ino
    └── v2i_common.h             (identical copy)
```

Exactly one `.ino` per folder, and each folder has the same name as its `.ino`. Do not leave your
old `intersection_esp32_fallback.ino` in `intersection_esp32/` (see Troubleshooting).

---

## a) How the code was checked (read this first)

- Both sketches compile with `g++ -Wall -Wextra` and **no warnings**. The build used the real
  **ArduinoJson 7.4.2** and **TM1637 1.2.0 (Avishay Orpaz)** sources, plus small PC stand-ins for
  the ESP32/ESP8266 Wi-Fi, UDP, WebServer and WebSockets APIs. The vehicle sketch was built three
  ways: ESP32, ESP32-S3 (`CONFIG_IDF_TARGET_ESP32S3`) and ESP8266.
- One intersection and six vehicle "boards" then ran together as separate programs, talking over
  real UDP sockets at 5× speed. The Serial lines in the test plan below come from that run.
- **Not done:** a build with the real Espressif/ESP8266 cores, because Arduino CLI was not available
  in my workspace. Your first build in Arduino IDE is the real compile check. If a core-version
  difference shows up, it will be a one-line API name; send me the error.
- All times and numbers in this README come from the PC bench or from the formulas. **None of them
  are hardware measurements.** Measure on the real prototype before quoting anything in the report or viva.

---

## b) What changed compared with your attached files

### Intersection (`intersection_esp32_fallback.ino` → `intersection_esp32.ino`)
1. **AUTO mode is the default.** The old `mode` + `fallbackActive` pair is replaced by three things:
   - *requested* mode: auto / fixed / adaptive
   - *target* mode: what the controller wants right now
   - *effective* mode: latched at each lane decision

   AUTO targets ADAPTIVE as soon as any packet arrives, and FIXED after 5 s with no packet
   (`AUTO_FIXED_AFTER_MS`). The new command `o` (and `/api/mode?m=auto`, WebSocket `"auto"`) returns
   to auto. `[STAT]`, the state JSON and the dashboard show requested and effective mode separately,
   plus `mode_reason`.
2. **Fixed → adaptive early end:** a fixed green with no demand on its lane is ended after the 5 s
   minimum green. I added `AUTO_SETTLE_MS = 1.5 s`: the early end waits until every vehicle has had
   time to send a packet. Without it, the first vehicle to connect ended the E green before the E
   vehicle had reported.
3. **Webster:** same formulas. Two differences from before:
   - I removed the old per-lane cap `y_i ≤ 1`, because your formula only caps Y.
   - `[PLAN]` now prints q, y, Y, L, C0 and g at every adaptive decision.

   The plan used for the running green (`decisionPlan`) is now kept apart from the 1 s preview used
   for red-time estimates. Before, the green time shown kept changing while that green was running.
4. **Emergency priority (all modes; the `EMERGENCY_IN_FIXED` switch is removed):**
   - The current green ends at once with yellow 3 s and all-red 1 s.
   - The priority green lasts at least 5 s and is held while the emergency vehicle is still
     approaching or crossing, up to 25 s.
   - If the emergency vehicle's lane is already green, that green is held instead.
   - When several emergency vehicles are waiting, the nearest one wins.
   - A running priority green is never cut by a second emergency vehicle. The second one goes next.
   - **One-normal-turn rule:** each lane that just had priority is flagged. It cannot get priority
     again until a normal green has run to its end. The old single variable failed with two
     emergency lanes: W and S took turns preempting, and N, with 3 queued vehicles, waited 86 s in
     the bench run.
   - The lane whose green was cut is served next (`RESUME_PREEMPTED_LANE`).
5. **Lane decision moved into `v2i_common.h` (`v2iClassify()`).** The intersection uses it to decide.
   The vehicle uses the same function only to print `[BASIS]`, so the thresholds can no longer drift
   apart. `tl` is used only for `[MISMATCH]`. I removed the old fallback that accepted a
   sender-claimed `"lane"` field when lat/lon were missing, because it broke your rule that the
   decision always comes from coordinates.
6. **Density check:** LOW/MEDIUM/HIGH per lane and overall, every 100 ms. All thresholds are named
   constants. The per-lane thresholds are **placeholders**, because you only gave the overall rule.
7. **Diagnostics:**
   - lost packets counted from `seq` gaps
   - RSSI, packet count and age per vehicle
   - `[CONN]` line when a vehicle first connects, `[LOST]` lines with statistics
   - `v` table extended, `r` toggles `[RX]`, `p` prints a preview plan, `h` shows help
8. **ACK** is now built with `snprintf` (about 110 B) and includes `pri`.
9. **Displays:** only one display is written per 50 ms slot. At your 250 µs bit delay one TM1637
   write blocks the loop for roughly 50 ms, so the old code (all four at once) blocked for about
   200 ms. Each display is fully rewritten every 5 s, and all four show 88:88 at power-on as a
   self-test.
10. **State JSON:** still starts with `"v":2` and keeps all the old keys. Added: `requested_mode`,
    `target_mode`, `mode_reason`, per-lane `density` and `approaching`, `queued_total` and
    `approaching_total`, per-vehicle `tl`, `rssi`, `pkts`, `lost` and `age_s`, and
    `timing.phase` and `timing.priority`.
11. **Network:** `softAPConfig()` fixes the IP at 192.168.4.1. Up to 10 clients are allowed (6
    vehicles + laptop + phone). At most 8 UDP packets are handled per loop pass.

### Vehicle (`vehicle_node.ino`)
1. **Bug fix (was in the original): the vehicle ran red lights.** Braking started one step too late,
   so the car overshot the stop line on red and then counted as "crossing". The new code brakes
   along the stopping profile and clamps the position at the stop point. A `committed` flag allows
   crossing only on green, or on a yellow it can no longer stop for. In the bench run no vehicle
   passed the stop line on red.
2. **Bug fix: the stop line moved from 10 m to 12 m.** At 10 m (equal to `JUNCTION_R_M`) the ±1 m
   noise made a stopped front vehicle flicker into CROSSING. It then dropped out of Qw and its lane
   was skipped. A `static_assert` now stops the build if the two values get too close.
3. Added `"tl"` and `"rssi"` to the packet. The packet is built with `snprintf` and checked against
   200 B; the bench run measured 120–123 B.
4. Wi-Fi no longer blocks setup for 15 s. It joins channel 6 directly, reconnects automatically and
   reopens the ACK port after a reconnect.
5. `[BASIS]` uses the shared `v2iClassify()` on the exact rounded values that were sent.
6. `TEST_SOURCE 1` replays the `REPLAY[]` table (renamed from `USE_RECORDED_TRIP`). The table now
   contains approach, queued, crossing and leaving rows.

---

## Pin map: kept as you had it

Sharing CLK (GPIO16) between the four TM1637 modules is fine. A TM1637 only starts listening when
its **own DIO** falls while CLK is high (the start condition). The three idle displays keep DIO high,
so they ignore the clock pulses meant for the fourth.

GPIO5 and GPIO15 are boot-strapping pins, but they need HIGH at boot, which the module pull-ups
provide. The map avoids the dangerous pins: GPIO12 (wrong level = boot failure), GPIO0, GPIO2 and
the flash pins 6–11.

Only change the map if one display shows garbage while the others are fine; that points to a wiring
fault. There are no spare safe GPIOs for separate CLK lines anyway.

---

## c) Upload and run

**1. Arduino IDE 2.x → Boards Manager**
- Install **esp32 by Espressif Systems** (2.0.x or 3.x).
- For the ESP8266 boards, install **esp8266 by ESP8266 Community**. If either core is not listed,
  add the URL under File → Preferences → Additional boards manager URLs:
  `https://espressif.github.io/arduino-esp32/package_esp32_index.json`
  `http://arduino.esp8266.com/stable/package_esp8266com_index.json`

**2. Library Manager:** **ArduinoJson** (v7.x, by Benoit Blanchon), **TM1637** (by Avishay Orpaz),
**WebSockets** (by Markus Sattler). WiFi, WebServer and WiFiUdp come with the cores.

**3. Intersection:** open `intersection_esp32/intersection_esp32.ino`.
Board: **ESP32 Dev Module** ("DOIT ESP32 DEVKIT V1" also works). Upload, then open the Serial Monitor at **115200**.
You should see `AP OK: SSID V2I-Junction-01 ... IP 192.168.4.1`, all four displays showing 88:88, then N green for 30 s.

**4. Vehicles:** open `vehicle_node/vehicle_node.ino` and set `#define BOARD_PRESET` to the number
for that board. Upload, then **change the number before the next board**. Two boards with the same
preset send the same id and get merged into one vehicle.

| Board type | Tools → Board | Extra settings |
|---|---|---|
| ESP32-S3 | **ESP32S3 Dev Module** | USB port labelled "USB": **USB CDC On Boot → Enabled** (otherwise the Serial Monitor stays blank). Port labelled "COM/UART": leave it Disabled. |
| ESP32 | **ESP32 Dev Module** | none |
| ESP8266 | **NodeMCU 1.0 (ESP-12E Module)**, or **LOLIN(WEMOS) D1 R2 & mini** for a Wemos D1 mini | none |

Any preset runs on any board. Label every board with its preset. A suggestion that spreads the hardware types:

| Preset | id | Role | Suggested board |
|---|---|---|---|
| 1 | 101 | normal, lane N, slot 0 | ESP32-S3 |
| 2 | 102 | normal, lane N, slot 1 | ESP32 |
| 3 | 103 | normal, lane N, slot 2 | ESP8266 |
| 4 | 104 | normal, lane E | ESP8266 |
| 5 | 201 | EMERGENCY, lane W, drives in after 30 s | ESP32-S3 or ESP32 |
| 6 | 202 | EMERGENCY, lane S, drives in after 70 s | ESP32 |

**5. Run order:** power the intersection first, wait for N GREEN, then power the vehicles.
The dashboard is at `http://192.168.4.1/` from a phone or laptop joined to `V2I-Junction-01`
(password `v2i12345`).

---

## d) Test plan with expected Serial lines

The line formats below are exact, and the values come from the PC bench run. I removed the timestamps
and replaced the bench's generic `ESP32` board names with the suggested boards. On hardware, use the
Serial Monitor's "Show timestamp" option; times, positions and RSSI will differ.

### Case 1: no vehicles connected → FIXED 30 s
Power only the intersection.
```
[SIG ] ALL RED 1.0s
[SIG ] lane N GREEN 30.0s (fixed 30s round-robin: auto, no vehicle connected)
[STAT] FIXED (auto: no vehicle connected -> fixed) req=auto | N:G E:R S:R W:R | cur=N GREEN 21.3s | veh=0 | Qw N=0.0 LOW E=0.0 LOW S=0.0 LOW W=0.0 LOW | overall=LOW
[SIG ] lane N YELLOW 3.0s (green time over)          <- 30 s after the green
[SIG ] ALL RED 1.0s                                  <- 3 s later
[SIG ] lane E GREEN 30.0s (fixed 30s round-robin: auto, no vehicle connected)   <- 1 s later
```
**Pass:** N → E → S → W, each 30 s green + 3 s yellow + 1 s all-red (34 s per lane, 136 s cycle).
The displays count down 00:30 to 00:00 on green and 00:03 to 00:00 on yellow. On red they show the
estimated wait.

### Case 2: vehicles 1–3 connected → automatic ADAPTIVE, lane N longest green
Power presets 1, 2, 3 (add 4 to show the E lane being given a shorter green).
```
[CONN] id=101 ESP32-S3 normal connected (1 vehicle(s)) - first vehicle
[MODE] auto: vehicle data received (1 connected) -> ADAPTIVE from the next lane decision
[STAT] FIXED (auto: 3 vehicle(s) sending data -> adaptive | switching at next lane decision) req=auto | ...
[MODE] switching to adaptive: lane E has no demand -> fixed green ended early after 17.2s   <- only if the running fixed green has no demand
[MODE] effective mode now ADAPTIVE (auto: 3 vehicle(s) sending data -> adaptive)
[PLAN] adaptive Qw=[3.0 0.5 0.0 0.0] q=[540 90 0 0]veh/h y=[0.300 0.050 0.000 0.000] Y=0.350 L=16s C0=44.6s g=[24.5 5.0 0.0 0.0]s
[SIG ] lane N GREEN 24.5s (adaptive Webster: Qw=3.0 y=0.300 HIGH density)
[RX  ] id=101 normal ESP32-S3 lat=31.500111 lon=74.299996 spd=0.0 hdg=181 -> lane=N tl=N QUEUED d=12.4m brg=358
```
Check the `[PLAN]` line by hand from your formulas (3 queued on N, 1 approaching on E):
q_N = 3 × 3600 / 20 = 540 veh/h, y_N = 540 / 1800 = 0.30, y_E = 0.05, Y = 0.35,
C0 = (1.5·16 + 5) / (1 − 0.35) = 44.6 s, g_N = (0.30 / 0.35)·(44.6 − 16) = 24.5 s,
g_E = 4.1 s, which is clamped up to 5.0 s.

Qw depends on whether the cars are QUEUED (weight 1) or APPROACHING (weight K = 0.5) at the moment
of the decision. The bench therefore also printed `g_N = 15.2 s` (3 approaching, Qw = 1.5) and
`22.7 s` (Qw = 2.5). **Pass:** N always gets the largest g, and lanes with no demand show `g=0.0`
and are skipped.

On a vehicle while it waits at its slot:
```
[TX  ] #25 id=101 normal ESP32-S3 lat=31.500111 lon=74.299996 spd=0.0 hdg=181 tl=N rssi=-50 (121 B) | sig=R STOPPED
[BASIS] bearing=358deg dist=12.4m hdg=181deg spd=0.0km/h => expect lane N, QUEUED  -> counts in Qw
[ACK ] seq=25 lane=N st=QUEUED sig=R rem=71.5s mode=fixed
```
`[BASIS]` (vehicle) and `[RX]` (intersection) must give the same lane and state. No `[MISMATCH]`
should appear; the bench run had none.

### Case 3: emergency vehicle 5 arrives → W green after about 4 s
Preset 5 parks out of range (400 m, IGNORED) for 30 s, then drives in from 140 m.
```
[PRIO] emergency id=201 detected on lane W d=137m APPROACHING -> priority requested
[PRIO] emergency id=201 on lane W -> ending lane N green now (yellow 3s + all-red 1s)
[SIG ] lane N YELLOW 3.0s (preempted by emergency vehicle)
[SIG ] ALL RED 1.0s
[SIG ] lane W GREEN 5.0s (EMERGENCY PRIORITY id=201 d=88m, hold until crossed, max 25s)
[PRIO] lane W GREEN for emergency id=201, 4.0 s after its request
[PRIO] emergency id=201 has crossed -> ending priority green on W after 7.0s
[PRIO] lane W waits one normal turn before it can get priority again
[SIG ] lane N GREEN 12.1s (adaptive Webster: ..., resumes lane cut by priority)
```
Vehicle 5 prints `[PRIO] GREEN on lane W, 4.0 s after ...`.

The 4.0 s (3 s yellow + 1 s all-red) applies when another lane is green at the request. It is shorter
if the junction is already in yellow or all-red, immediate if W is already green (`... already green
-> holding green`), and longer in two cases:
- another emergency vehicle's priority green is running (the bench showed 5.5–6.0 s for vehicle 202)
- W is still waiting its one normal turn (the bench showed 6.6 s)

### Case 4: all vehicles switched off → back to FIXED
```
[LOST] id=101 ESP32-S3 - no packet for 3.1s (pkts=279 lost=0) -> removed, 5 vehicle(s) left
...
[LOST] id=103 ESP8266 - no packet for 3.1s (pkts=279 lost=0) -> removed, 0 vehicle(s) left
[MODE] auto: no vehicle heard for 5s -> FIXED from the next lane decision
[MODE] effective mode now FIXED (auto: no vehicle heard for 5s -> fixed)     <- when the running green ends
[SIG ] lane E GREEN 30.0s (fixed 30s round-robin: auto, no vehicle connected)
```
**Pass:** `[LOST]` about 3 s after power-off, the `[MODE]` line at about 5 s, and the switch at the
end of the running phase (the green is not cut).

### Manual overrides (also tested on the bench)
`f`, `a` and `o` in the Serial Monitor (send with "No line ending" or "Newline"; both work):
```
[MODE] requested=fixed (from serial 'f') -> target fixed, effective adaptive now, change applies at the next lane decision
[MODE] effective mode now FIXED (manual: fixed forced)
```
WebSocket `{"mode":"adaptive"}` or plain `adaptive` gives the same line with `(from WebSocket)`.

### curl: inject a test vehicle (laptop joined to V2I-Junction-01)
Linux / macOS / Git-Bash:
```bash
curl -X POST http://192.168.4.1/api/vehicle -H "Content-Type: application/json" \
  -d '{"t":"pos","id":901,"ty":0,"lat":31.499700,"lon":74.300000,"spd":0,"hdg":0,"seq":1,"hw":"laptop","tl":"S"}'
```
Windows PowerShell (use `curl.exe`, not the `curl` alias):
```powershell
curl.exe -X POST http://192.168.4.1/api/vehicle -H "Content-Type: application/json" -d "{\"t\":\"pos\",\"id\":901,\"ty\":0,\"lat\":31.499700,\"lon\":74.300000,\"spd\":0,\"hdg\":0,\"seq\":1,\"hw\":\"laptop\",\"tl\":\"S\"}"
```
Expected reply (`sig`, `rem` and `mode` depend on the moment; the bench gave both of these in different runs):
```
{"t":"ack","id":901,"seq":1,"mode":"fixed","lane":"S","st":"QUEUED","sig":"R","rem":78.2,"pri":0}
{"t":"ack","id":901,"seq":1,"mode":"fixed","lane":"S","st":"QUEUED","sig":"G","rem":4.2,"pri":0}
```
That point is 33 m south, stationary and heading north, so it is QUEUED on S. An injected vehicle
is removed after 3 s like any other. To keep it alive, repeat the request:
`for i in $(seq 1 60); do curl -s -X POST ... "seq":$i ...; sleep 0.5; done`.
- **Emergency:** set `"ty":1`, which gives `pri:1` and a priority green on S.
- **Mismatch check:** send `"lat":31.500000,"lon":74.300600,"hdg":270,"tl":"N"`, which is really
  the E arm. Expected: `[MISMATCH] id=902 computed lane E but test data says N`.
- **Other endpoints:** `curl http://192.168.4.1/api/state` and
  `curl "http://192.168.4.1/api/mode?m=auto"`.

---

## e) Troubleshooting

| Symptom | Cause and fix |
|---|---|
| **Vehicle can't join Wi-Fi** (`[WIFI] not connected (status 1/6)` repeating) | Is the intersection powered and showing `AP OK`? SSID and password are case-sensitive and must match `v2i12345` in *both* copies of `v2i_common.h`. ESP32 chips only work on 2.4 GHz. Keep boards within a few metres for the demo. More than 10 clients (including phones) will be refused. ESP8266: power-cycle after flashing; a weak USB supply causes brown-out reconnect loops. |
| **No ACK** (`[TX]` lines but no `[ACK]`; vehicle stops after 3 s) | Check that the intersection prints `[RX]` for that id (toggle with `r` if you turned it off). If no `[RX]`: the vehicle is on another network, or `INTERSECTION_IP_STR` / port differ between the two header copies. If `[RX]` but no `[ACK]`: another sketch on the vehicle uses port 4211, or the vehicle board was flashed with an old sketch. |
| **Wrong lane / `[MISMATCH]`** | Compare `[BASIS]` with `[RX]`. Both come from the same function, so a difference means different input: usually two different `v2i_common.h` copies (diff them) or a wrong `CENTER_LAT/LON`. IGNORED with "heading away" means `hdg` does not point at the centre within ±60°. "out of range" means it is beyond 150 m (normal for parked emergency presets). |
| **Mode does not switch** | Check `[STAT] ... req=`. If it says `req=fixed` or `req=adaptive`, a manual override is active: press `o`. Fixed → adaptive waits for the next lane decision, and a fixed green with demand on its lane runs its full 30 s. Adaptive → fixed needs **5 s with no packets from any vehicle**. A parked emergency vehicle still sends packets, so it keeps the mode adaptive; this is intended. A laptop or phone on the AP does not count. |
| **`redefinition of 'void setup()'`** or `'vehs' was declared here` | Arduino merges every `.ino` in a folder into one file. Move `intersection_esp32_fallback.ino` (or any other `.ino`) out of the folder. Keep exactly one `.ino` per folder, named after the folder. |
| **TM1637 blank** | VCC/GND swapped or missing common ground. Power the modules from **3.3 V** (their pull-ups then keep the ESP32 pins at 3.3 V; HW-069 runs fine at 3.3 V). Check that the 88:88 self-test appears at boot; if not, check CLK on GPIO16 and that each DIO wire goes to its own GPIO. |
| **TM1637 garbled / random segments** | Long jumper wires or the modules' on-board capacitors slow the edges, worse with 4 modules on one CLK. Raise `DISPLAY_BIT_DELAY_US` from 250 to 400. Keep wires short and twist each DIO with a GND wire. The 5 s full refresh repairs one-off glitches. If one module is always bad while the others are fine, that DIO wire or module is faulty. |
| **ESP32-S3 Serial Monitor empty** | Set Tools → USB CDC On Boot → **Enabled** when you use the native "USB" port. |
| **Two vehicles act as one** | The same `BOARD_PRESET`, and so the same id, was flashed on two boards. |

---

## Placeholders to tune or measure before the viva
- `K_APPROACH = 0.5`: hand-tuned weight (your planned tuning or ML step).
- Per-lane density thresholds `LANE_*`: toy-scale guesses.
- `OBS_WINDOW_S = 20 s`: toy-scale constant.
- `AUTO_SETTLE_MS = 1.5 s` and `PRIO_MIN_GREEN_MS = 5 s`: my choices; tune them if needed.
- To **measure on hardware** (none measured yet):
  - emergency detection-to-green time (`[PRIO] ... s after its request`)
  - packet loss (`lost` in `v`)
  - RSSI at the demo distances
  - ACK round-trip time
  - TM1637 write stalls with your wiring
