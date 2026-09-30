# Hosting the server in the cloud (no PC needed)

The app needs the backend server running somewhere. Instead of your PC, it can run on a cloud host.
Phones then connect over the internet from anywhere (Wi-Fi or mobile data), using an `https://`
address. This guide uses [Render](https://render.com) because it can create everything from the
`render.yaml` file in this repository, with no terminal. The `Dockerfile` also works on any other
host that runs containers.

What gets created:

| | |
|---|---|
| `smart-traffic-api` | the backend (web service built from `Dockerfile`), with HTTPS |
| `smart-traffic-db` | a PostgreSQL database |

On the first start the server creates its database tables, **your admin account** (the email and
password you enter in step 2) and the placeholder intersections I1-I4, then starts. You do not run
any commands.

## Free plan: know the limits

- The free web service **sleeps after about 15 minutes** without use. The next request wakes it up,
  which takes up to about a minute; the app waits for it and shows a message while it waits. While a
  phone is tracking, the server stays awake.
- Render's **free database is time-limited** (30 days when this guide was written; check
  render.com/pricing). When it expires, its data is deleted. For a longer project, upgrade the database
  to a paid plan, or use another PostgreSQL provider (see "Using another database" below).
- Check Render's current pricing before relying on it; free plans change.

## 1. Create a Render account

Go to https://render.com, choose **Get Started**, and sign up **with GitHub** (the account that owns
`SAAD-2113/Smart-Traffic-Management-App`). When asked, allow Render to access that repository.

## 2. Create the Blueprint

1. In the Render dashboard: **New** → **Blueprint**.
2. Select the repository **Smart-Traffic-Management-App**.
3. **Branch:** choose `claude/busy-ritchie-x9ac7i` (the branch with the code). If Render does not let
   you pick a branch, merge that branch into `main` on GitHub first, then use `main`.
4. Render reads `render.yaml` and shows the two resources. It asks for two values:
   - `BOOTSTRAP_ADMIN_EMAIL`: the email you want to log in with, e.g. `manager@example.com`
   - `BOOTSTRAP_ADMIN_PASSWORD`: at least 10 characters, with at least one letter and one digit
5. Click **Apply** (or **Deploy Blueprint**). The first build takes a few minutes.

## 3. Find the server address

Open **smart-traffic-api** in the dashboard. At the top is its address, like
`https://smart-traffic-api.onrender.com` (Render may add letters if the name is taken).
Check it in a browser: `https://<your address>/api/v1/health` should show `"status":"ok"`.

If the deploy failed, open **Logs**. A line starting with `bootstrap failed:` names the setting to fix
(for example a password that is too short): change it under **Environment** and click
**Manual Deploy** → **Deploy latest commit**.

## 4. Connect the app

1. Open the app. On the login screen, tap **Server**.
2. Enter your address, with `https://` and **without** `:8000`, e.g. `https://smart-traffic-api.onrender.com`.
3. Tap **Test**, wait for "Connected" (up to a minute if the server was asleep), then **Save**.
4. Sign in with the email and password from step 2. You get the manager screens.

Everyone else (drivers) enters the same address and taps **Create account**.

## Everyday use

- Nothing to start or stop. If the server was asleep, the first screen takes up to a minute.
- New code pushed to the branch is deployed automatically.
- Demo traffic: **More → Settings → Demo simulation → Start simulation** in the manager app.
- Change your password in the app (**More → Settings → Change password**). Changing
  `BOOTSTRAP_ADMIN_PASSWORD` later does **not** change an existing account.
- Password-reset emails are not configured on this prototype server; reset links appear in the
  service **Logs**. To send real emails, add `SMTP_HOST`, `SMTP_PORT`, `SMTP_USERNAME`,
  `SMTP_PASSWORD`, `SMTP_FROM` and `PASSWORD_RESET_URL` under **Environment**.

## Using another database

Any PostgreSQL works. Replace `DATABASE_URL` under **Environment** with its connection string as given
by the provider (`postgres://...` or `postgresql://...`, `?sslmode=require` is fine); the server converts it
to the driver it needs. A new, empty database gets its tables and your admin account on the next start.

## Other hosts

The image is standard. On any container host or a VPS:

```bash
docker build -t smart-traffic-backend .
docker run -p 8000:8000 \
  -e DATABASE_URL='postgresql://user:password@host:5432/dbname' \
  -e JWT_SECRET='<at least 32 random characters>' \
  -e BOOTSTRAP_ADMIN_EMAIL='manager@example.com' -e BOOTSTRAP_ADMIN_PASSWORD='<password>' \
  -e SEED_CORRIDOR=adaptive -e DEMO_MODE=true \
  smart-traffic-backend
```

Put it behind HTTPS (most hosts do this for you). Run **one** instance: the live dashboard feed and the
traffic engine run inside the server process.

## Before real use

This is a prototype/demo configuration (`ENVIRONMENT=development`, demo simulation allowed). For real
users set `ENVIRONMENT=production`, `DEMO_MODE=false` and the SMTP settings; the server then refuses
to start if any of them is unsafe. See `docs/SECURITY_AND_PRIVACY.md`.
