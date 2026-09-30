from datetime import datetime, timezone


def utcnow() -> datetime:
    """The only clock the backend uses: timezone-aware UTC."""
    return datetime.now(timezone.utc)
