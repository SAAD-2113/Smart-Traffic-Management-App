"""Create an ADMIN or MANAGER account. These roles cannot be self-registered through the API.

Usage (from the backend folder):
    uv run python -m scripts.create_user --role ADMIN --email admin@example.com --name "System Admin"
"""
import argparse
import asyncio
import getpass
import sys

from app.core.errors import AppError
from app.db.session import SessionLocal, engine
from app.models.enums import UserRole
from app.schemas.user import validate_password_strength
from app.services import auth_service


async def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--role", choices=[UserRole.ADMIN.value, UserRole.MANAGER.value], required=True)
    parser.add_argument("--email", required=True)
    parser.add_argument("--name", required=True)
    args = parser.parse_args()

    password = getpass.getpass("Password: ")
    if password != getpass.getpass("Confirm password: "):
        print("Passwords do not match.")
        return 1
    try:
        validate_password_strength(password)
    except ValueError as exc:
        print(exc)
        return 1

    try:
        async with SessionLocal() as db:
            user = await auth_service.create_user(
                db, email=args.email, password=password, full_name=args.name, role=UserRole(args.role)
            )
    except AppError as exc:
        print(f"Error: {exc.message}")
        return 1
    finally:
        await engine.dispose()

    print(f"Created {user.role.value} {user.email} (id {user.id})")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
