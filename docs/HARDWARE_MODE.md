# Hardware mode: the ESP32 intersection monitor

The app starts with a choice of two modes:

| Mode | What it is | Needs |
|---|---|---|
| **Hardware Prototype** | A read-only live monitor for the physical V2I intersection, which an ESP32 controls | The phone on the ESP32's Wi-Fi. No login, no internet. |
| **Software System** | The full app: login, driver and manager apps, trips and analysis | The backend server |

With **Remember my choice** ticked, the app opens the same mode on the next launch. Both modes
have a **Switch mode** option that returns to the choice:
- **Hardware mode:** the header.
- **Software mode:** the login screen, the "Connecting…" screen, the manager's Settings and the
  driver's Profile.

A driver who is tracking a trip must stop tracking first.

The code of the two modes is kept apart:
- `mobile/lib/hardware/` holds Hardware mode.
- `mobile/lib/mode/` holds the mode selection.
- The rest of `mobile/lib/` is Software mode.

Hardware mode never builds the software app, so it makes no login, server or tile requests. Its
only connection is the WebSocket to the controller.

## Using it with the hardware

1. Power on the ESP32. Its Wi-Fi network is called **STMS-RSU**.
2. On the phone, join STMS-RSU in the Wi-Fi settings. The network has no internet; if Android
   asks, choose to stay connected.
3. Open the app and tap **Hardware Prototype**.
4. The badge in the header shows the connection state:
   - **ONLINE** (green): a state frame arrived within the last 1.5 s.
   - **STALE** (amber): connected, but no frame for more than 1.5 s.
   - **OFFLINE** (red): the socket is closed. The app retries every 2 s.

The controller address defaults to `ws://192.168.4.1:81/`. To change it, tap the settings icon
and change the IP and port. The app remembers them.

**The app only listens.** It never sends anything to the controller. Mode changes happen with
the physical button on the hardware, so nothing in the app can make the signals unsafe. The
emergency popup is a notification only.

## What the dashboard shows

| # | Section | Content |
|---|---|---|
| 1 | Header | Intersection ID, connection badge, time since the last update, data source, settings, **Switch mode** |
| 2 | Status row | Mode badge (ADAPTIVE / FIXED), controller state, congestion, total vehicles |
| 3 | Live signals | Top-down intersection. Each signal head (N, S, E, W) shows the lamp reported in `signals`. The large countdown is in the middle, with "NORTH/SOUTH — GREEN" below it. |
| 4 | Adaptive timing | Target, elapsed and remaining time, a progress bar, the next phase and the controller's `reason`. In fixed mode the card is titled **Fixed plan**. |
| 5 | Traffic | Per approach: queued, approaching, level, and an emergency icon when `ev` is true. Also the demand per phase. |
| 6 | Signal plan | NS and EW rows; green, yellow, all-red and red in seconds |
| 7 | V2I & system | Link, active vehicles, packets/s, age of the last packet, rejected packets, controller uptime, firmware, clients, free heap |
| 8 | Vehicles | Collapsed by default. ID, type, approach, state, distance, speed in km/h, ETA. |
| 9 | Event log | Last 20 events, newest first, in phone local time |

Banners:
- **Red: EMERGENCY PRIORITY — approach — vehicle** while `preempt.active` is true.
- **Amber: V2I link lost — fixed-time fallback active** when `ctrl` is `fallback` or `v2i.link`
  is `lost`.
- **Purple: SIMULATED DATA** whenever the data comes from the simulator. It stays after
  switching back to the ESP32 until real frames replace the simulated state.
- **Unsupported data version** when frames with a `"v"` other than 2 arrive. Those frames are
  ignored.
- A connection banner when the state is STALE or OFFLINE, with a reminder to join STMS-RSU.

Each `ev_request` event opens a popup for 5 s with the vehicle, the approach and the result
(granted or rejected), and a **Dismiss** button.

Any missing or unexpected field is shown as "—" (or as its raw text); a bad frame never
crashes the app.

## Countdown synchronisation

The countdown always comes from the hardware; the app has no free-running signal timer.
- **On each state frame:** `deadline = now + timing.remaining_ms`. `now` is a monotonic clock,
  not the phone's wall clock.
- **Between frames:** the display shows `ceil((deadline − now) / 1000)` and redraws about 10
  times per second.
- **New frame:** the countdown re-anchors to its `remaining_ms`, whether the number goes up
  (green extended) or down.
- **STALE or OFFLINE:** the display freezes at the moment the data stopped, i.e. 1.5 s after
  the last frame or when the socket closed. The lamps turn grey and the card is labelled
  **Last known state**. It does not keep counting down.
- **Controller restart:** when `uptime_ms` is lower than in the previous frame, the event log
  gets a **Controller restarted** entry.

## Frame format (protocol version 2)

The controller sends JSON text frames:
- a `"type": "state"` frame every 500 ms and immediately on any change;
- a `"type": "event"` frame when something happens.

The example state frame and all allowed values are in the hardware specification. A copy of
the example is in `tools/hardware_test_server.py`.

The app reads `spd` as **metres per second** and shows km/h (× 3.6), like the rest of the
system, which uses SI units. If the firmware sends km/h, change `speedUnitToKmh` in
`mobile/lib/hardware/model/frame.dart` to 1.

## Simulator (no hardware needed)

In the dashboard settings, set **Data source** to **Simulator**.
- **Frames:** exactly the same format and rate as the ESP32. They go through the same parser.
- **Cycle:** NS green → NS yellow (3 s) → all-red (2 s) → EW green → EW yellow (3 s) →
  all-red (2 s) → repeat.
- **Green time:** adaptive green = clamp(6 + 2 × demand, 10, 60) s. Demand is the vehicles
  queued or approaching on that phase when its green starts. Fixed mode uses 20 s.
- **Vehicles:** arrive at random rates that change every few seconds, queue on red and leave on
  green.
- **Emergencies:** about once a minute an emergency vehicle requests priority. Most requests are
  granted. A granted request cuts a conflicting green short, after its minimum green, through
  yellow and all-red, and holds the green until the vehicle has passed.
- **Simulator controls** (in the settings sheet, affecting simulated data only): press the
  mode button, simulate a V2I link loss, request an emergency now.

The SIMULATED DATA banner is always visible while the simulator is the source.

## Test server (a laptop instead of the ESP32)

`tools/hardware_test_server.py` is a WebSocket server that sends the example frame and some
special cases. It needs only Python 3 and its standard library.

```powershell
python tools/hardware_test_server.py                       # example frame every 500 ms, port 8765
python tools/hardware_test_server.py --scenario jump       # remaining_ms 5000 -> 12000
python tools/hardware_test_server.py --scenario missing    # fields missing, unexpected values
python tools/hardware_test_server.py --scenario emergency  # ev_request events and preemption
python tools/hardware_test_server.py --scenario fallback   # V2I lost
python tools/hardware_test_server.py --scenario version    # "v": 3 frames (ignored)
python tools/hardware_test_server.py --scenario restart    # uptime goes back
```

1. Connect the phone and the laptop to the same Wi-Fi.
2. In the app's hardware settings, enter the laptop's IP address and port 8765.
3. On Windows, allow Python through the firewall for private networks.

## Platform settings changed for Hardware mode

**Android** (`mobile/android/app/src/main/`):
- **`AndroidManifest.xml`:** adds the `ACCESS_NETWORK_STATE` permission. It is a normal
  permission, granted at install without a prompt. The app needs it to find the Wi-Fi network.
- **`MainActivity.java`:** a method channel `com.fyp.smart_traffic/hardware` with two jobs.
  - *Wi-Fi binding.* STMS-RSU has no internet, so Android may send the app's traffic over
    mobile data instead. While Hardware mode is open, the app follows the Wi-Fi network with
    `ConnectivityManager.registerNetworkCallback`, for Wi-Fi with or without internet. It binds
    the app process to that network with `bindProcessToNetwork`, so the WebSocket to
    192.168.4.1 goes over Wi-Fi. When the user leaves Hardware mode, the binding is released and
    Software mode uses the normal network again. The settings sheet shows whether Wi-Fi is in use.
  - *Keep the screen on.* `FLAG_KEEP_SCREEN_ON` is set while the dashboard is open and cleared
    afterwards.
- **`res/xml/network_security_config.xml`:** cleartext traffic was already allowed, for the
  development backend on the LAN; this now also covers `ws://` to the controller. Only the
  comment changed. The controller's address is editable, so cleartext cannot be limited to one
  domain entry.

**iOS** (`mobile/ios/`, generated for this change with `flutter create --platforms=ios`):
- **`Runner/Info.plist`:**
  - `NSLocalNetworkUsageDescription`: the text iOS shows when it asks for local-network access.
  - `NSAppTransportSecurity` → `NSAllowsLocalNetworking = true`: plain `ws://` to local
    addresses. Internet addresses still need HTTPS.
  - `NSLocationWhenInUseUsageDescription`: Software mode's trip tracking needs it on iOS.
- **`Runner/AppDelegate.swift`:** the same method channel. `keepScreenOn` sets
  `UIApplication.shared.isIdleTimerDisabled`. iOS keeps local-network traffic on Wi-Fi by
  itself, so no binding is needed.
- **Untested:** the iOS project has not been built here, because that needs a Mac with Xcode.

## Acceptance tests

| # | Test | How it is covered |
|---|---|---|
| 1 | Fresh install shows the mode selection before login; Hardware opens with no login, offline | `test/mode_test.dart`. Hardware mode never creates the login or server client. On a phone: airplane mode on, Wi-Fi only. |
| 2 | Simulator lamps follow the sequence; the countdown never ends after the lamp changed; banner visible | `test/hardware/simulator_test.dart` (sequence, 3 s and 2 s intervals, the green formula, deadline consistency, 500 ms cadence), `dashboard_test.dart` (banner) |
| 3 | Simulator switched off mid-countdown: STALE/OFFLINE, frozen and grey within 1.5 s | `monitor_test.dart`, `dashboard_test.dart`. Checked in the web build: switching to the ESP32 source shows OFFLINE at once, with grey lamps and a frozen countdown. |
| 4 | Live test server with the example frame: every card shows the example values | `dashboard_test.dart`, and the web build connected to `tools/hardware_test_server.py` |
| 5 | `remaining_ms` jumping 5000 → 12000 re-anchors at once | `monitor_test.dart`, and `--scenario jump` |
| 6 | A frame with missing fields shows "—" and does not crash | `frame_test.dart`, `dashboard_test.dart`, and `--scenario missing` |
| 7 | `ev_request` shows the popup; `preempt.active` shows the red banner | `dashboard_test.dart`, and `--scenario emergency` |
| 8 | Switch mode returns to the selection from both modes | `mode_test.dart` (hardware header, login screen) |
