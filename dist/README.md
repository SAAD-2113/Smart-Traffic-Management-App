# Android APK

Smart Traffic app 1.2.0 (versionCode 4), package `com.fyp.smart_traffic`. Same app in three files:

| File | For | SHA-256 |
|---|---|---|
| `smart-traffic-v1.2.0.apk` (34.7 MB) | universal: every phone (64-bit and 32-bit ARM) plus x86_64 (emulator) | `4adb632c5934fcb3e984d7694ae09c88d265d736c2fa6d57552f9e6b016e94eb` |
| `smart-traffic-v1.2.0-arm64-v8a.apk` (15.1 MB) | almost all current phones (64-bit ARM), smaller download | `8454654cf17da58bb537e63c16392936bab5831983161883220b89f74c180ce9` |
| `smart-traffic-v1.2.0-armeabi-v7a.apk` (14.7 MB) | older 32-bit phones | `aa80bb5255ffcc165cd225cca754297ae495ccdfa026f9c00b7f746145319e40` |

If unsure, use the universal APK.

What's new in 1.2.0:
- **Mode selection at start-up**, with "Remember my choice" and a "Switch mode" option in both
  modes:
  - **Hardware Prototype:** a read-only, offline monitor for the physical ESP32 intersection. The
    phone joins the controller's Wi-Fi "STMS-RSU"; there is no login and no server. It shows the
    live signal heads, a countdown synchronised to the controller, adaptive timing with its reason,
    traffic per approach, the signal plan, V2I and system health, vehicles and an event log, with
    emergency and fallback banners.
  - A built-in **simulator** for working without the hardware, always marked "SIMULATED DATA".
  - See `docs/HARDWARE_MODE.md`.
  - **Software System:** the app as before.
- **Signal timing as a plain table** (green / yellow / all-red / red) instead of timing bars.

1.1.0 added the traffic control dashboard (fixed-time / adaptive with reasons), signal lights on
the live map and the rush-hour simulation.

It works with the cloud server (`docs/DEPLOY_CLOUD.md`). It installs over 1.0.x and 1.1.0 as an
update (same signing key), and your data stays.

| | |
|---|---|
| Android | 7.0 (API 24) or newer; built for API 36 |
| Permissions | Internet, network state (Hardware mode: keep the connection on the controller's Wi-Fi), precise/approximate location (while in use), foreground location service, wake lock, notifications |
| Signed with | a demo certificate (`CN=Smart Traffic FYP Demo`), SHA-256 `9f514a58a0d16acf9b3fba27f71d2565c0d687d35a1ab2001ce80af4b320d380` |

Install: copy it to the phone and open it (allow installing unknown apps when asked), or
`adb install <file>.apk`. Then set the server address on the login screen
(see `docs/DEPLOY_CLOUD.md` for a cloud server, `docs/SETUP_WINDOWS.md` for a server on your PC).

These APKs are for testing the prototype. A build you make yourself with `flutter build apk --release` uses
a different signing key, so uninstall this one before installing yours.

How it was built: the build environment could not reach Google's Maven repository, which Gradle needs,
so these APKs were assembled from the same sources without Gradle: Flutter's release AOT compiler, the
official Flutter engine, and the same AndroidX / Play Services library versions, then linked, dexed,
aligned and signed with the Android SDK tools. `flutter build apk --release` (see
`docs/SETUP_WINDOWS.md`, and the CI workflow) is the standard way to build it.
