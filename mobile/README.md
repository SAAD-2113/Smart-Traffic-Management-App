# Smart Traffic mobile app (Flutter)

On launch the app asks for a mode (with "Remember my choice"; "Switch mode" returns to it):

- **Hardware Prototype:** a read-only, offline monitor of the physical ESP32 intersection
  (WebSocket `ws://192.168.4.1:81/` on the controller's Wi-Fi "STMS-RSU", or a built-in
  simulator). No login, no server. See `docs/HARDWARE_MODE.md`.
- **Software System:** the full app below.

In Software mode, the role the backend returns after login decides which app the user sees:

- **Driver (END_USER):** vehicle setup and Vehicle ID, Home (start/stop tracking, GPS quality, speed,
  upload status and offline queue), Trips, Emergency (authorized emergency
  vehicles only: request authorization, press-and-hold + confirm to activate), Profile.
- **Manager (MANAGER/ADMIN):**
  - **Dashboard ("Traffic Control Center").** How many intersections are fixed-time, adaptive or
    in emergency priority. Each intersection gets a control card with the mode, the reason, the
    traffic behind it and the green/yellow/red timing against the fixed plan, plus the mode-change
    log.
  - **Live map.** Signal lights at every intersection: a head per approach on the side its
    traffic arrives from, a hub in the mode colour, and a countdown.
  - **Other screens.** Vehicles, Intersections (observed / calculated / estimated metrics,
    approaches, data quality, control policy AUTO / FIXED / ADAPTIVE), Traffic analysis,
    Emergency (authorizations and events), Signal control (plans, modes, timing), History,
    Settings (demo simulation with rush hour, server, theme).
  - Live updates come over the WebSocket, with polling as the fallback. The app only displays the
    server's control status; it never works out the mode or the timing itself.

The Android build (`com.fyp.smart_traffic`, Android 7.0+) contains both roles; the web build is used as
a desktop manager dashboard.

## Build and run

```powershell
flutter pub get
flutter run                                   # connected phone or emulator
flutter build apk --release                   # build\app\outputs\flutter-apk\app-release.apk
flutter build web --no-web-resources-cdn      # build\web (manager dashboard)
flutter analyze; flutter test
```

Set the backend address on the login screen (**Server**): `http://<PC LAN IP>:8000` for a phone on
the same Wi-Fi, `http://10.0.2.2:8000` for the Android emulator. Release signing: see
`docs/SETUP_WINDOWS.md` (`android/key.properties`, never committed).

## Structure

```
lib/
  main.dart                       startup (local settings only), then the mode root
  mode/                           mode selection, remembered choice, "Switch mode"
  hardware/                       Hardware mode, separate from the rest: protocol v2 frame parser,
                                  link status and countdown (monitor.dart), live WebSocket and
                                  simulator sources, Android/iOS helpers, dashboard UI
  app.dart                        Software mode: session scope, role routing
  core/                           config (server URL, installation id), API client, token store,
                                  key-value storage, theme and status colours, units, validators
  data/models, data/repositories  typed views of the API JSON; auth, vehicle and manager API calls
  data/local/telemetry_queue.dart offline packet queue (SQLite)
  services/                       location (geolocator foreground service), packet builder,
                                  upload policy (batching, backoff, backfill window), tracking controller
  features/auth|driver|manager    screens and their controllers (provider / ChangeNotifier)
  widgets/                        shared widgets and charts (fl_chart); brand.dart (header, stat
                                  tiles, buttons), signal_widgets.dart (mode badge, traffic light,
                                  control card, timing diagram, map signal marker)
```

## Tracking behaviour

- Location permission "While using the app" only; tracking runs as a foreground service with a
  notification, so it continues with the screen off. No background-location permission is requested.
- One fix per second at most; fixes worse than 100 m accuracy are not sent (the server additionally
  excludes fixes worse than 50 m from traffic metrics); speed and heading are sent in SI units
  (m/s, degrees), unknown speed stays null.
- Every packet goes into the local queue first and is uploaded in order every 2 s (up to 100 packets
  per request, so a backlog drains quickly). Network and server errors keep the packets and retry with exponential
  backoff (max 30 s). Packets older than 9.5 minutes are discarded, as the server rejects them after 10.
- The server validates every packet again; the app shows the last rejection reason, if any.

## Notes

- Map tiles: OpenStreetMap (`tile.openstreetmap.org`), no API key. Heavy use needs your own tile server
  (Settings → map tiles).
- Fonts: Roboto is bundled (`assets/fonts`, Apache License 2.0) so the web build works offline.
- The app allows plain `http://` for the LAN prototype (`android/app/src/main/res/xml/network_security_config.xml`).
  Use HTTPS and remove that allowance for any deployment beyond the lab.
