import re

from app.models.enums import UserRole
from app.services.email import ConsoleEmailSender
from tests.conftest import API, PASSWORD


async def test_register_login_and_me(client):
    r = await client.post(f"{API}/auth/register", json={
        "email": "Driver@Example.com", "password": PASSWORD, "fullName": "Ali Driver"})
    assert r.status_code == 201, r.text
    body = r.json()
    assert body["email"] == "driver@example.com"
    assert body["role"] == "END_USER"
    assert "passwordHash" not in body and "password" not in body

    r = await client.post(f"{API}/auth/login", json={"email": "driver@example.com", "password": PASSWORD})
    assert r.status_code == 200
    tokens = r.json()
    assert tokens["tokenType"] == "Bearer" and tokens["refreshToken"].startswith("rt_")

    me = await client.get(f"{API}/me", headers={"Authorization": f"Bearer {tokens['accessToken']}"})
    assert me.status_code == 200 and me.json()["email"] == "driver@example.com"


async def test_register_rejects_client_supplied_role(client):
    r = await client.post(f"{API}/auth/register", json={
        "email": "sneaky@example.com", "password": PASSWORD, "fullName": "Sneaky", "role": "MANAGER"})
    assert r.status_code == 422
    assert r.json()["error"]["code"] == "VALIDATION_ERROR"


async def test_duplicate_email_rejected(client):
    payload = {"email": "dup@example.com", "password": PASSWORD, "fullName": "Dup User"}
    assert (await client.post(f"{API}/auth/register", json=payload)).status_code == 201
    payload["email"] = "DUP@example.com"
    r = await client.post(f"{API}/auth/register", json=payload)
    assert r.status_code == 409 and r.json()["error"]["code"] == "EMAIL_ALREADY_REGISTERED"


async def test_weak_passwords_rejected(client):
    for weak in ("short1", "onlyletterslong", "1234567890123"):
        r = await client.post(f"{API}/auth/register", json={
            "email": "weak@example.com", "password": weak, "fullName": "Weak"})
        assert r.status_code == 422, weak


async def test_validation_errors_do_not_echo_passwords(client):
    r = await client.post(f"{API}/auth/register", json={
        "email": "x@example.com", "password": "secretpw", "fullName": "X"})
    assert r.status_code == 422
    assert "secretpw" not in r.text


async def test_login_errors_are_generic(client, create_user):
    await create_user("known@example.com")
    wrong = await client.post(f"{API}/auth/login", json={"email": "known@example.com", "password": "Wrong-pass-123"})
    unknown = await client.post(f"{API}/auth/login", json={"email": "nobody@example.com", "password": "Wrong-pass-123"})
    assert wrong.status_code == unknown.status_code == 401
    assert wrong.json()["error"]["code"] == unknown.json()["error"]["code"] == "INVALID_CREDENTIALS"
    assert wrong.json()["error"]["message"] == unknown.json()["error"]["message"]


async def test_me_requires_valid_token(client):
    assert (await client.get(f"{API}/me")).json()["error"]["code"] == "NOT_AUTHENTICATED"
    r = await client.get(f"{API}/me", headers={"Authorization": "Bearer not-a-jwt"})
    assert r.status_code == 401 and r.json()["error"]["code"] == "INVALID_TOKEN"


async def test_refresh_rotation_and_reuse_detection(client, create_user, login):
    await create_user("rot@example.com")
    _, first = await login("rot@example.com")

    r = await client.post(f"{API}/auth/refresh", json={"refreshToken": first["refreshToken"]})
    assert r.status_code == 200
    second = r.json()
    assert second["refreshToken"] != first["refreshToken"]

    # Replaying the old token means it was stolen: the whole session is revoked.
    r = await client.post(f"{API}/auth/refresh", json={"refreshToken": first["refreshToken"]})
    assert r.status_code == 401 and r.json()["error"]["code"] == "REFRESH_TOKEN_REUSED"
    r = await client.post(f"{API}/auth/refresh", json={"refreshToken": second["refreshToken"]})
    assert r.status_code == 401


async def test_logout_revokes_refresh_token(client, create_user, login):
    await create_user("out@example.com")
    _, tokens = await login("out@example.com")
    assert (await client.post(f"{API}/auth/logout", json={"refreshToken": tokens["refreshToken"]})).status_code == 204
    r = await client.post(f"{API}/auth/refresh", json={"refreshToken": tokens["refreshToken"]})
    assert r.status_code == 401


async def test_password_reset_flow(client, create_user, login):
    await create_user("reset@example.com")
    _, old_session = await login("reset@example.com")
    ConsoleEmailSender.outbox.clear()

    r = await client.post(f"{API}/auth/password/forgot", json={"email": "ghost@example.com"})
    assert r.status_code == 202 and len(ConsoleEmailSender.outbox) == 0

    r = await client.post(f"{API}/auth/password/forgot", json={"email": "reset@example.com"})
    assert r.status_code == 202 and len(ConsoleEmailSender.outbox) == 1
    token = re.search(r"token=(pr_[A-Za-z0-9_\-]+)", ConsoleEmailSender.outbox[-1].body).group(1)

    new_password = "N3wPassword-2026"
    r = await client.post(f"{API}/auth/password/reset", json={"token": token, "newPassword": new_password})
    assert r.status_code == 204

    bad = await client.post(f"{API}/auth/login", json={"email": "reset@example.com", "password": PASSWORD})
    assert bad.status_code == 401
    await login("reset@example.com", new_password)

    # Token is single-use, and old sessions were signed out.
    r = await client.post(f"{API}/auth/password/reset", json={"token": token, "newPassword": "An0ther-pass-99"})
    assert r.status_code == 400 and r.json()["error"]["code"] == "INVALID_RESET_TOKEN"
    r = await client.post(f"{API}/auth/refresh", json={"refreshToken": old_session["refreshToken"]})
    assert r.status_code == 401


async def test_change_password_keeps_only_current_session(client, create_user, login):
    await create_user("change@example.com")
    headers_a, session_a = await login("change@example.com")
    _, session_b = await login("change@example.com")

    r = await client.post(f"{API}/auth/password/change", headers=headers_a, json={
        "currentPassword": PASSWORD, "newPassword": "Chang3d-password"})
    assert r.status_code == 204

    assert (await client.post(f"{API}/auth/refresh", json={"refreshToken": session_a["refreshToken"]})).status_code == 200
    assert (await client.post(f"{API}/auth/refresh", json={"refreshToken": session_b["refreshToken"]})).status_code == 401


async def test_change_password_requires_correct_current(client, create_user, login):
    await create_user("wrongcur@example.com")
    headers, _ = await login("wrongcur@example.com")
    r = await client.post(f"{API}/auth/password/change", headers=headers, json={
        "currentPassword": "Not-the-password1", "newPassword": "Chang3d-password"})
    assert r.status_code == 400 and r.json()["error"]["code"] == "INVALID_CURRENT_PASSWORD"


async def test_disabled_account_cannot_login(client, create_user, as_role, login):
    user = await create_user("gone@example.com")
    user_headers, _ = await login("gone@example.com")
    admin = await as_role(UserRole.ADMIN)

    r = await client.patch(f"{API}/admin/users/{user.id}/status", headers=admin, json={"isActive": False})
    assert r.status_code == 200 and r.json()["isActive"] is False

    r = await client.post(f"{API}/auth/login", json={"email": "gone@example.com", "password": PASSWORD})
    assert r.status_code == 403 and r.json()["error"]["code"] == "ACCOUNT_DISABLED"
    assert (await client.get(f"{API}/me", headers=user_headers)).status_code == 401
