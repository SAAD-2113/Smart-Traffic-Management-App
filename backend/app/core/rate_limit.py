from slowapi import Limiter
from slowapi.util import get_remote_address

from app.core.config import get_settings

# Keyed by client IP. Behind a tunnel/proxy, run uvicorn with --proxy-headers so the real IP is used.
limiter = Limiter(key_func=get_remote_address, enabled=get_settings().rate_limit_enabled)
