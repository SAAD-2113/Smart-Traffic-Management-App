# Android APK

Smart Traffic app 1.0.0 (versionCode 1), package `com.fyp.smart_traffic`. Same app in three files:

| File | For | SHA-256 |
|---|---|---|
| `smart-traffic-v1.0.0-arm64-v8a.apk` (14.9 MB) | almost all current phones (64-bit ARM) | `b3ff6afb25a04299ca09dad46a345b3e85d531d959a6fa4ac973f489afff2985` |
| `smart-traffic-v1.0.0-armeabi-v7a.apk` (14.5 MB) | older 32-bit phones | `87e20b597fa7c16bebf4d7fd555ff36ad15c9943f1d207baf497ddd91056f264` |
| `smart-traffic-v1.0.0.apk` (34.1 MB) | universal: both of the above plus x86_64 (emulator) | `25fc6893ed089a294ba293b5c216eb0bd1034d5ddde7733008503a1f63800a27` |

If unsure, use the universal APK.

| | |
|---|---|
| Android | 7.0 (API 24) or newer; built for API 36 |
| Permissions | Internet, precise/approximate location (while in use), foreground location service, wake lock, notifications |
| Signed with | a demo certificate (`CN=Smart Traffic FYP Demo`), SHA-256 `9f514a58a0d16acf9b3fba27f71d2565c0d687d35a1ab2001ce80af4b320d380` |

Install: copy it to the phone and open it (allow installing unknown apps when asked), or
`adb install <file>.apk`. Then set the server address on the login screen
(see `docs/SETUP_WINDOWS.md`).

These APKs are for testing the prototype. A build you make yourself with `flutter build apk --release` uses
a different signing key, so uninstall this one before installing yours.

How it was built: the build environment could not reach Google's Maven repository, which Gradle needs,
so these APKs were assembled from the same sources without Gradle: Flutter's release AOT compiler, the
official Flutter engine, and the same AndroidX / Play Services library versions, then linked, dexed,
aligned and signed with the Android SDK tools. `flutter build apk --release` (see
`docs/SETUP_WINDOWS.md`, and the CI workflow) is the standard way to build it.
