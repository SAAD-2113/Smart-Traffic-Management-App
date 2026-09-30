# Backend (Phase 2)

FastAPI + SQLAlchemy 2 (async) + PostgreSQL. API docs at http://localhost:8000/docs once running.

## 1. Install tools (Windows, PowerShell)

```powershell
winget install --id Git.Git
winget install --id Python.Python.3.12
winget install --id astral-sh.uv
winget install --id Docker.DockerDesktop
```

Restart the terminal afterwards. Open Docker Desktop once and let it finish setting up WSL 2.
If you already run a native PostgreSQL on port 5432, stop it or change the port in `infra/docker-compose.yml`.

## 2. Start the database

From the repository root:

```powershell
copy infra\.env.example infra\.env      # then set POSTGRES_PASSWORD
docker compose -f infra/docker-compose.yml --env-file infra/.env up -d
docker compose -f infra/docker-compose.yml --env-file infra/.env ps   # wait for "healthy"
```

## 3. Configure and install the backend

```powershell
cd backend
copy .env.example .env
python -c "import secrets; print(secrets.token_urlsafe(48))"   # paste into JWT_SECRET
# Set DATABASE_URL to use the same password as infra/.env (URL-encode @ # % characters)
uv sync
```

## 4. Create the schema

```powershell
uv run alembic revision --autogenerate -m "phase 2 core schema"
uv run alembic upgrade head
```

Open the generated file in `alembic/versions/` and read it once before committing it.
Future schema changes follow the same two commands.

## 5. Create accounts and seed the corridor

```powershell
uv run python -m scripts.create_user --role ADMIN --email admin@example.com --name "System Admin"
uv run python -m scripts.create_user --role MANAGER --email manager@example.com --name "Traffic Manager"
uv run python -m scripts.seed_intersections
```

The seeded I1-I4 coordinates are placeholders. Update them with your real junctions
(`PATCH /api/v1/intersections/{id}`) before any real data collection.

## 6. Run

```powershell
uv run uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

`--host 0.0.0.0` lets a phone on the same Wi-Fi reach the backend. When exposing it through a
tunnel (Cloudflare Tunnel) for phones on mobile data, add `--proxy-headers` so rate limits see
the real client IP.

## 7. Test

```powershell
uv run pytest -v
```

Tests use a throwaway SQLite database per test, so they do not need Docker running.

## Endpoints in this phase

| Method | Path | Who |
|---|---|---|
| GET | `/api/v1/health` | public |
| POST | `/api/v1/auth/register` · `/login` · `/refresh` · `/logout` | public |
| POST | `/api/v1/auth/password/forgot` · `/reset` | public |
| POST | `/api/v1/auth/password/change` | logged in |
| GET / PATCH | `/api/v1/me` · GET `/api/v1/me/vehicles` | logged in |
| POST | `/api/v1/vehicles` · GET `/vehicles/{id}` | END_USER (own vehicles) |
| POST / GET / DELETE | `/api/v1/vehicles/{id}/devices[/{deviceId}]` | END_USER (own vehicles) |
| GET | `/api/v1/manager/vehicles[/{id}]` · PATCH `/manager/vehicles/{id}/status` | MANAGER, ADMIN |
| GET / POST / PATCH / DELETE | `/api/v1/intersections[/{id}]`, `/approaches`, `/links` | MANAGER, ADMIN |
| POST | `/api/v1/admin/managers` · PATCH `/admin/users/{id}/status` · GET `/admin/vehicles/{id}` | ADMIN |
| POST / GET | `/api/v1/admin/controller-clients[/{id}/revoke]` | ADMIN |
| GET | `/api/v1/controller/ping` (header `X-Controller-Key`) | Raspberry Pi / SUMO bridge |

## Known limitations (by design for this phase)

- Email verification is not implemented yet; accounts are usable immediately.
- Access tokens stay valid for up to 15 minutes after logout or account disable, because they
  are stateless. Refresh tokens are revoked immediately.
- In development, password-reset links are printed to the backend console. Production mode
  refuses to start without SMTP settings.
- The database user from Docker is a superuser; a least-privilege app role is part of Phase 10.
