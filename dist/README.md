# Android APK

Smart Traffic app 1.1.0 (versionCode 3), package `com.fyp.smart_traffic`. Same app in three files:

| File | For | SHA-256 |
|---|---|---|
| `smart-traffic-v1.1.0-arm64-v8a.apk` (15.0 MB) | almost all current phones (64-bit ARM) | `db6e0e81d844bd06dfa90638b8f88e26d9af5bfbb1f7b22ac9f8d387c7b5d1c4` |
| `smart-traffic-v1.1.0-armeabi-v7a.apk` (14.5 MB) | older 32-bit phones | `f099d3ea94b7b4cfb1df2b491c0dd2e120b2f440b47faa0b055ee06a97a88c67` |
| `smart-traffic-v1.1.0.apk` (34.3 MB) | universal: both of the above plus x86_64 (emulator) | `c0b9a93215f965d2542ea45bfec128f681402fc94ada26b13433e3a7b040206b` |

If unsure, use the universal APK.

What's new in 1.1.0:
- **Traffic control dashboard.** Each intersection runs fixed-time while traffic is normal. When
  congestion is significant it switches to adaptive timing. The app shows the mode, the reason, the
  traffic behind it (vehicles, average speed, waiting time, congestion), and the green, yellow and
  red times against the fixed plan. Mode changes are logged and announced.
- **Signal lights on the live map** at every intersection: one head per approach, a hub coloured
  by mode, and a countdown.
- **Rush-hour simulation** in Settings → Demo, so the switch can be demonstrated.
- A refreshed look (gradient header, cards, light and dark themes).

It works with the cloud server (`docs/DEPLOY_CLOUD.md`). It installs over 1.0.x as an update
(same signing key), and your data stays. Use it with a server running the same code; Render
updates itself from the branch.

| | |
|---|---|
| Android | 7.0 (API 24) or newer; built for API 36 |
| Permissions | Internet, precise/approximate location (while in use), foreground location service, wake lock, notifications |
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
