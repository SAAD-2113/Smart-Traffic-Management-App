# Android APK

`smart-traffic-v1.0.0.apk`: Smart Traffic app 1.0.0 (versionCode 1), package `com.fyp.smart_traffic`.

| | |
|---|---|
| Android | 7.0 (API 24) or newer; built for API 36 |
| CPU | arm64-v8a, armeabi-v7a (phones), x86_64 (emulator) |
| Permissions | Internet, precise/approximate location (while in use), foreground location service, wake lock, notifications |
| Signed with | a demo certificate (`CN=Smart Traffic FYP Demo`), SHA-256 `9f514a58a0d16acf9b3fba27f71d2565c0d687d35a1ab2001ce80af4b320d380` |
| File SHA-256 | `25fc6893ed089a294ba293b5c216eb0bd1034d5ddde7733008503a1f63800a27` |

Install: copy it to the phone and open it (allow installing unknown apps when asked), or
`adb install smart-traffic-v1.0.0.apk`. Then set the server address on the login screen
(see `docs/SETUP_WINDOWS.md`).

This APK is for testing the prototype. A build you make yourself with `flutter build apk --release` uses
a different signing key, so uninstall this one before installing yours.

How it was built: the build environment could not reach Google's Maven repository, which Gradle needs,
so this APK was assembled from the same sources without Gradle: Flutter's release AOT compiler, the
official Flutter engine, and the same AndroidX / Play Services library versions, then linked, dexed,
aligned and signed with the Android SDK tools. `flutter build apk --release` (see
`docs/SETUP_WINDOWS.md`, and the CI workflow) is the standard way to build it.
