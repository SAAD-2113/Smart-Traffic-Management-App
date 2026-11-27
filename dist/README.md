# Android APK

## 1.4.2 (current): GitHub Releases

Smart Traffic app 1.4.2, package `com.fyp.smart_traffic`, built by GitHub Actions with the
standard `flutter build apk --release`.

**Download:** the repository's [Releases page](https://github.com/SAAD-2113/Smart-Traffic-Management-App/releases)
→ **Smart Traffic v1.4.2** → `smart-traffic-v1.4.2.apk` (one file for 64-bit and 32-bit ARM phones and
x86_64 emulators). No GitHub sign-in is needed. CI publishes a release by itself whenever `main`
gets a new version number in `mobile/pubspec.yaml`.

What's new in 1.4.2:
- Bottom sheets, dialogs and menus are opaque: the text of the screen behind no longer shows through.
- Web build: Hardware mode's simulator works (it showed a grey screen), and Digital V2I rejects a
  vehicle id written as a decimal (`"id":7.0`) as the ESP32 does. The Android app was not affected
  by these two.

What 1.4.1 added:
- The server address is preset to the hosted server,
  `https://smart-traffic-management-app.onrender.com`, so a new install can sign in straight away.
  **Server** on the login screen still changes it (for example to a PC on the same Wi-Fi). An address
  saved earlier is kept.

What 1.4.0 added:
- **New look:** frosted-glass surfaces (background blur, translucent cards, hairline borders)
  over a white (light theme) or black (dark theme) background with soft red, amber and green
  signal glows. The colours are the three signal colours plus a warm orange, with graphite
  neutrals. There is no blue anywhere, including the chart colours, which were re-checked for
  colour-blind readers.
- **Traffic-light app icon:** an adaptive icon (with a themed monochrome version on Android
  13+), a matching splash screen and web icons.
- Same features as 1.3.0.

What 1.3.0 added:
- **Digital V2I mode**, a third card on the mode selection: a digital twin of the V2I firmware v3.
  An ADMIN / MANAGER phone runs the intersection controller. Driver phones join with a code and
  run as vehicles: simulated, live GPS or a replay of their own recorded trip. The server decides
  each account's role, vehicle ID and emergency status. Traffic goes over the server's relay or
  over a local Wi-Fi / hotspot (the phone serves the ESP32's HTTP, WebSocket and UDP endpoints).
  Phones can also act as vehicles of the physical ESP32 junction. The mode also has a test
  injector, metrics computed from the recorded log, a Fixed vs Adaptive comparison, and CSV /
  log export to `Downloads/DigitalV2I`. See `docs/DIGITAL_V2I.md`.
- **Hardware mode reads firmware v3 frames**: a four-lane dashboard with the per-lane MM:SS
  displays. Its simulator is now the firmware v3 twin. See `docs/HARDWARE_MODE.md`.

| | |
|---|---|
| Android | 7.0 (API 24) or newer |
| Permissions | the same as 1.2.0: Internet, network state, precise/approximate location (while in use), foreground location service, wake lock, notifications |
| Signed with | the Android **debug** key of the CI runner (the repository has no release-key secrets) |

**Uninstall the old app first** (1.2.0, or a 1.3.0 CI build). They were signed with different
keys, so Android refuses to install 1.4.2 over them. Uninstalling removes what is stored on the phone: the server address, the
remembered mode, the sign-in and any GPS points still waiting in the offline queue (finish uploading
first). Accounts, vehicles and trips already sent stay on the server.

Builds signed with a debug key may also differ in signature from one CI run to the next. To make
every CI build install over the previous one, add four repository secrets
(`ANDROID_KEYSTORE_BASE64`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`, `ANDROID_STORE_PASSWORD`).
`.github/workflows/ci.yml` then signs with your key (see `mobile/android/app/build.gradle.kts`).

Not yet done with 1.4.2: installing it on a physical phone. Do that first (`docs/DIGITAL_V2I.md`,
"What has not been verified").

## 1.2.0 (the files in this folder; no Digital V2I)

| File | For | SHA-256 |
|---|---|---|
| `smart-traffic-v1.2.0.apk` (34.7 MB) | universal: every phone (64-bit and 32-bit ARM) plus x86_64 (emulator) | `4adb632c5934fcb3e984d7694ae09c88d265d736c2fa6d57552f9e6b016e94eb` |
| `smart-traffic-v1.2.0-arm64-v8a.apk` (15.1 MB) | almost all current phones (64-bit ARM), smaller download | `8454654cf17da58bb537e63c16392936bab5831983161883220b89f74c180ce9` |
| `smart-traffic-v1.2.0-armeabi-v7a.apk` (14.7 MB) | older 32-bit phones | `aa80bb5255ffcc165cd225cca754297ae495ccdfa026f9c00b7f746145319e40` |

1.2.0 added the mode selection (Hardware Prototype monitor for the ESP32 Part-3 controller, with a
simulator; Software System) and the signal timing table. 1.1.0 added the traffic control
dashboard, signal lights on the live map and the rush-hour simulation. Signed with a demo
certificate (`CN=Smart Traffic FYP Demo`, SHA-256
`9f514a58a0d16acf9b3fba27f71d2565c0d687d35a1ab2001ce80af4b320d380`). 1.2.0 was assembled without
Gradle: the build environment back then also had no access to Google's Maven repository.

## Install

Copy the APK to the phone and open it (allow installing unknown apps when asked), or run
`adb install <file>.apk`. The app is preset to the hosted server; to use another one, change it under
**Server** on the login screen. For a cloud server see
`docs/DEPLOY_CLOUD.md`; for a server on your PC see `docs/SETUP_WINDOWS.md`. Hardware mode needs no
server.

To build it yourself, run `flutter build apk --release` in `mobile/` (see `docs/SETUP_WINDOWS.md`).
A self-built APK is signed with your own key, so uninstall any other build first.
