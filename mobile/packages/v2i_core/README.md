# v2i_core

Pure-Dart port of the V2I firmware v3 in [`docs/firmware-v3`](../../../docs/firmware-v3) (intersection
controller, lane decision, vehicle unit). No Flutter imports: it runs inside the app, headless, and in
unit tests with a fake clock.

| Firmware                                   | Here                                             |
|--------------------------------------------|--------------------------------------------------|
| `v2i_common.h` constants, `v2iClassify()`  | `config.dart`, `geometry.dart`, `classify.dart`  |
| `intersection_esp32.ino`                   | `controller.dart` (`IntersectionController`)     |
| `vehicle_node.ino`                         | `vehicle.dart` (`V2IVehicle`, `PRESETS`, `REPLAY`) |
| `snprintf` packets / ACK, ArduinoJson reads | `packets.dart`                                   |
| `millis()`                                 | `MonoClock` (`StopwatchClock`, `FakeClock`)      |
| `Serial.print*`                            | `V2ILog` (same line text and tags)               |

Rules of the port:

- Same formulas, constants, thresholds, state names, reason strings, log lines and state-JSON keys
  (in the same order, `"v":2` first). Values the firmware keeps in `float` are rounded to float32
  at the same places; `%.Nf` is printed with C rounding (`cfix`).
- Signal timing uses only the injected monotonic clock, never wall-clock time.
- Lane and state come from lat/lon/speed/heading only; `tl` is used for the `[MISMATCH]` check only.
- The vehicle never computes its own signal: it shows the last ACK, counts `rem` down locally and
  falls back to RED after 3 s without an ACK. `v2iClassify()` on the vehicle only prints `[BASIS]`.

Digital-twin additions (not in the firmware): the junction centre and names come from the session,
`hdg`/`tl`/`rssi` may be left out (live GPS), `Veh.rttMs` / `V2IVehicle.rttSamples` record the
packet -> ACK round trip, and an optional wall clock labels log lines for exports.

Run the tests (76) from this folder:

```bash
dart pub get
dart test
```
