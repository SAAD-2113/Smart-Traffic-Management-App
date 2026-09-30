# Running the system on Windows

This guide takes a Windows 10/11 PC from nothing to: backend running, manager dashboard open, and the
Android app on a phone sending GPS data. Commands are for PowerShell.

```
Phone (Android app) ──Wi-Fi──> PC: backend :8000 ──> PostgreSQL (Docker) or SQLite file
Browser (manager dashboard) ───┘         └── SUMO bridge (optional)
```

## 1. Install the tools

```powershell
winget install --id Git.Git
winget install --id Python.Python.3.12
winget install --id astral-sh.uv
winget install --id Docker.DockerDesktop          # optional: only for PostgreSQL (step 3a)
```

For the mobile app (only if you want to build it yourself, the APK is provided):

- Flutter SDK 3.4x: https://docs.flutter.dev/get-started/install/windows/mobile, unzip to `C:\dev\flutter`
  and add `C:\dev\flutter\bin` to PATH.
- Android Studio: https://developer.android.com/studio. In **More Actions → SDK Manager**, install an
  Android SDK Platform, **Android SDK Command-line Tools** and **Android SDK Platform-Tools**.
- Then `flutter doctor --android-licenses` and `flutter doctor` (fix everything it reports under Flutter
  and Android toolchain; Visual Studio is not needed).

Restart PowerShell after installing so PATH changes apply.

## 2. Get the code

```powershell
git clone https://github.com/SAAD-2113/Smart-Traffic-Management-App.git
cd Smart-Traffic-Management-App
```

## 3. Database

### 3a. PostgreSQL in Docker (recommended)

```powershell
copy infra\.env.example infra\.env        # set POSTGRES_PASSWORD to a password of your choice
docker compose -f infra/docker-compose.yml --env-file infra/.env up -d
docker compose -f infra/docker-compose.yml --env-file infra/.env ps     # wait for "healthy"
```

The database listens on `127.0.0.1:5432` only.

### 3b. SQLite (quick start, no Docker)

Skip Docker and use a local file (fine for a demo on one PC; use PostgreSQL for data collection):

```
DATABASE_URL=sqlite+aiosqlite:///./smart_traffic.db
```

## 4. Backend

```powershell
cd backend
copy .env.example .env
python -c "import secrets; print(secrets.token_urlsafe(48))"
```

Edit `backend\.env`:

- `JWT_SECRET` = the value printed above.
- `DATABASE_URL` = `postgresql+asyncpg://traffic:<POSTGRES_PASSWORD>@localhost:5432/smart_traffic`
  (URL-encode `@ # %` in the password) or the SQLite URL from 3b.
- `DEMO_MODE=true` if you want the simulated fleet (Settings → Demo simulation in the manager app).
- `CORS_ORIGINS=["http://localhost:8080"]` for the web dashboard (step 7).

Then:

```powershell
uv sync
uv run alembic upgrade head
uv run python -m scripts.create_user --role ADMIN --email admin@example.com --name "System Admin"
uv run python -m scripts.create_user --role MANAGER --email manager@example.com --name "Traffic Manager"
uv run python -m scripts.seed_intersections --adaptive
uv run uvicorn app.main:app --host 0.0.0.0 --port 8000
```

`create_user` asks for the password (it is never passed on the command line). `seed_intersections`
creates the placeholder corridor I1-I4; replace the coordinates with your real intersections in the
manager app (Intersections) before collecting real data. `--adaptive` puts them in adaptive (advisory)
mode; without it they run fixed-time.

Check: open http://localhost:8000/docs.

> Upgrading a database created with the Phase 2 code? If you made the schema with your own
> `alembic revision --autogenerate` file, delete that file, run `uv run alembic stamp 0001`, then
> `uv run alembic upgrade head`.

### Let the phone reach the PC

1. Find the PC's Wi-Fi address: `ipconfig` → "Wireless LAN adapter Wi-Fi" → IPv4 Address, e.g.
   `192.168.1.20`.
2. Allow the port through Windows Firewall (PowerShell **as Administrator**):

   ```powershell
   New-NetFirewallRule -DisplayName "Smart Traffic backend" -Direction Inbound -Protocol TCP -LocalPort 8000 -Action Allow -Profile Private
   ```

   The Wi-Fi network must be set to **Private** in Windows settings.
3. On the phone's browser, open `http://192.168.1.20:8000/api/v1/health`; it should show `"status":"ok"`.

Phone and PC must be on the same Wi-Fi network (university networks often block device-to-device
traffic; a phone hotspot with the PC connected to it works). For phones on mobile data, expose the
backend over HTTPS with a tunnel (e.g. Cloudflare Tunnel) and start uvicorn with `--proxy-headers`.

## 5. Install the Android app

**Provided APK:** copy `smart-traffic-v1.0.0.apk` to the phone and open it (allow "Install unknown apps"
for your file manager when asked). Android 7.0 or newer.

**Build it yourself:**

```powershell
cd mobile
flutter pub get
flutter build apk --release        # output: build\app\outputs\flutter-apk\app-release.apk
flutter install                     # or: adb install build\app\outputs\flutter-apk\app-release.apk
```

During development, `flutter run` starts it on a connected phone (USB debugging on) or an emulator.

### Signing your own release

Without extra setup, release builds are signed with the debug key: fine for test phones, not for a store.
To sign with your own key:

```powershell
keytool -genkey -v -keystore $env:USERPROFILE\smart-traffic.jks -keyalg RSA -keysize 2048 -validity 10000 -alias smarttraffic
```

Create `mobile\android\key.properties` (git-ignored, never commit it or the keystore):

```
storePassword=<the password you chose>
keyPassword=<the password you chose>
keyAlias=smarttraffic
storeFile=C:\\Users\\<you>\\smart-traffic.jks
```

`flutter build apk --release` then signs with it. An APK signed with a different key cannot be
installed over the provided one; uninstall the old app first.

## 6. Use the app

1. On the login screen, tap **Server** and enter `http://<PC IP>:8000`, then **Test** and **Save**.
2. **Driver:** Create account → register a vehicle (the server gives it a Vehicle ID) → **Start
   tracking** → allow location "While using the app" and notifications. Keep the phone on the dashboard;
   tracking continues with the screen off (a notification is shown).
3. **Manager:** sign in with the manager account. Dashboard, live map, intersections, traffic analysis,
   emergency authorizations, signals, history. On a phone the manager screens use a bottom bar; on a
   tablet or the web a side rail.
4. **Emergency vehicles:** register the vehicle as Ambulance/Fire/Police, request authorization from the
   Emergency screen; a manager approves it under Emergency. Only then can the driver activate
   emergency mode (press and hold, then confirm).

Map tiles come from OpenStreetMap, so the phone needs internet access for the map background; everything
else only needs the backend.

## 7. Manager dashboard in a browser (optional)

```powershell
cd mobile
flutter build web --no-web-resources-cdn
cd build\web
python -m http.server 8080
```

Open http://localhost:8080 and set the server address to `http://localhost:8000`. The origin must be in
`CORS_ORIGINS`.

## 8. SUMO simulation (optional)

See `sumo_bridge/README.md`: `uv sync`, `uv run python build_network.py`, create a SUMO_BRIDGE controller
key as admin, then `uv run python bridge.py`. SUMO is installed by `uv sync` (no separate download).

## 9. Tests

```powershell
cd traffic_engine; uv run --group dev pytest
cd ..\backend;     uv run pytest
cd ..\mobile;      flutter test
```

## Troubleshooting

| Problem | Fix |
|---|---|
| App says it cannot reach the server | Same Wi-Fi? Firewall rule (step 4)? Server address uses the PC IP, not `localhost`? Backend started with `--host 0.0.0.0`? |
| `password authentication failed` on startup | The password in `DATABASE_URL` differs from `infra/.env`; special characters must be URL-encoded. |
| `port 5432 already in use` | A native PostgreSQL is running; stop it or change the port in `infra/docker-compose.yml`. |
| Map is grey | No internet on the phone (OSM tiles), or the tile server is rate-limiting. Data still works. |
| GPS quality "No fix" | Go outdoors; enable precise location for the app in Android settings. |
| Tracking stops when the app is swiped away on some phones | Disable battery optimisation for Smart Traffic (Settings → Apps → Battery → Unrestricted). |
| Demo simulation button disabled | `DEMO_MODE=true` in `backend\.env`, restart the backend. Never in production. |
| 429 Too many requests on login | Wait a minute (5 logins per minute per IP). |
| `flutter build apk` fails downloading Gradle or dependencies | Needs internet access to services.gradle.org, dl.google.com and repo.maven.apache.org. |
