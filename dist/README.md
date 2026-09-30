# Android APK

Smart Traffic app 1.0.1 (versionCode 2), package `com.fyp.smart_traffic`. Same app in three files:

| File | For | SHA-256 |
|---|---|---|
| `smart-traffic-v1.0.1-arm64-v8a.apk` (14.9 MB) | almost all current phones (64-bit ARM) | `df0ba28ff9f8c8ec6551c29f5f10cc136619187996447df893c804bb8b58a3e6` |
| `smart-traffic-v1.0.1-armeabi-v7a.apk` (14.5 MB) | older 32-bit phones | `a8b1a1a34dab1a88e9085f965408a3d95a730931ea4b1441f54e6118632c2aee` |
| `smart-traffic-v1.0.1.apk` (34.1 MB) | universal: both of the above plus x86_64 (emulator) | `f54de4811d71fe1b791be7a8756e5c910169a4b86158d25047cabff630de0de5` |

If unsure, use the universal APK.

1.0.1 works with a cloud-hosted server (`docs/DEPLOY_CLOUD.md`): it waits up to a minute for a sleeping
free-tier server and says so. It installs over 1.0.0 as an update (same signing key); your data stays.

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
