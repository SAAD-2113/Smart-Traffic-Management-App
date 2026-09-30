# Backend server image (FastAPI + traffic_engine). Build from the repository root:
#   docker build -t smart-traffic-backend .
#   docker run -p 8000:8000 --env-file backend/.env smart-traffic-backend
# Configuration comes only from environment variables (see backend/.env.example and
# docs/DEPLOY_CLOUD.md); no secrets are baked into the image.
FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=never

RUN pip install --no-cache-dir uv==0.8.17

WORKDIR /app
# The backend depends on ../traffic_engine (path dependency), so keep the same layout.
COPY traffic_engine /app/traffic_engine
COPY backend /app/backend
WORKDIR /app/backend
RUN uv sync --frozen --no-dev \
    && useradd --create-home --uid 10001 app \
    && chown -R app /app

USER app
ENV PATH="/app/backend/.venv/bin:$PATH"
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s \
    CMD python -c "import os, urllib.request; urllib.request.urlopen(f'http://127.0.0.1:{os.environ.get(\"PORT\", \"8000\")}/api/v1/health', timeout=4)"
CMD ["sh", "start.sh"]
