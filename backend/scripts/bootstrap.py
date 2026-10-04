"""First-start setup for hosted deployments, driven by environment variables.

Cloud hosts often give no terminal to run create_user / seed_intersections, so the container
runs this before the server starts (see start.sh). It is safe to run on every start:

- BOOTSTRAP_ADMIN_EMAIL + BOOTSTRAP_ADMIN_PASSWORD (+ optional BOOTSTRAP_ADMIN_NAME):
  creates that ADMIN account if no account with the email exists. An existing account is
  never changed, so the password can be changed later in the app.
- SEED_CORRIDOR=auto|fixed|adaptive: creates the placeholder I1-I4 corridor if it is missing
  (`adaptive` is accepted as the old spelling of `auto`).

Usage: python -m scripts.bootstrap
"""
import asyncio
import os
import sys
from collections.abc import Mapping

from pydantic import EmailStr, TypeAdapter, ValidationError
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.session import SessionLocal, engine
from app.models.enums import UserRole
from app.repositories import user_repo
from app.schemas.user import validate_password_strength
from app.services import auth_service, intersection_service
from scripts.seed_intersections import CODES, seed_corridor


class BootstrapError(Exception):
    pass


async def bootstrap(db: AsyncSession, env: Mapping[str, str]) -> list[str]:
    """Apply the requested setup; returns what was done, for the log."""
    done: list[str] = []
    email = env.get("BOOTSTRAP_ADMIN_EMAIL", "").strip().lower()
    password = env.get("BOOTSTRAP_ADMIN_PASSWORD", "")
    if email or password:
        if not (email and password):
            raise BootstrapError("Set both BOOTSTRAP_ADMIN_EMAIL and BOOTSTRAP_ADMIN_PASSWORD, or neither.")
        try:
            TypeAdapter(EmailStr).validate_python(email)
        except ValidationError as exc:
            raise BootstrapError(f"BOOTSTRAP_ADMIN_EMAIL is not a valid email address: {email!r}") from exc
        if await user_repo.get_by_email(db, email) is not None:
            done.append(f"admin {email} already exists (unchanged)")
        else:
            try:
                validate_password_strength(password)
            except ValueError as exc:
                raise BootstrapError(f"BOOTSTRAP_ADMIN_PASSWORD: {exc}") from exc
            await auth_service.create_user(
                db, email=email, password=password, role=UserRole.ADMIN,
                full_name=env.get("BOOTSTRAP_ADMIN_NAME", "").strip() or "System Admin",
            )
            done.append(f"created admin {email}")

    corridor = env.get("SEED_CORRIDOR", "").strip().lower()
    if corridor:
        policy = {"auto": "AUTO", "adaptive": "AUTO", "fixed": "FIXED"}.get(corridor)
        if policy is None:
            raise BootstrapError("SEED_CORRIDOR must be 'auto' or 'fixed'.")
        existing = [code for code in CODES if await intersection_service.get_by_code(db, code) is not None]
        if len(existing) == len(CODES):
            done.append("corridor I1-I4 already present (unchanged)")
        else:
            await seed_corridor(db, policy)
            done.append(f"seeded corridor I1-I4 ({policy})")
    return done


async def main() -> int:
    try:
        async with SessionLocal() as db:
            for line in await bootstrap(db, os.environ):
                print(f"bootstrap: {line}")
    except BootstrapError as exc:
        print(f"bootstrap failed: {exc}", file=sys.stderr)
        return 1
    finally:
        await engine.dispose()
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
