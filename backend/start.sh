#!/bin/sh
# Container entry point: migrate the database, apply first-start setup, then serve.
# Hosting platforms set $PORT; behind their HTTPS proxy, --proxy-headers makes rate limits
# see each client's real address instead of the proxy's.
set -e
alembic upgrade head
python -m scripts.bootstrap
exec uvicorn app.main:app --host 0.0.0.0 --port "${PORT:-8000}" --proxy-headers --forwarded-allow-ips "*"
