import uuid
from datetime import timedelta

import jwt
import pytest

from app.core.config import get_settings
from app.core.errors import AppError
from app.core.security import (
    create_access_token,
    decode_access_token,
    hash_opaque_token,
    hash_password,
    new_opaque_token,
    verify_password,
)
from app.core.time import utcnow


def test_password_hash_roundtrip():
    hashed = hash_password("Str0ngPassw0rd")
    assert hashed.startswith("$argon2id$")
    assert verify_password("Str0ngPassw0rd", hashed)
    assert not verify_password("wrong-password1", hashed)
    assert not verify_password("anything1", "not-a-hash")


def test_access_token_roundtrip():
    user_id, session_id = uuid.uuid4(), uuid.uuid4()
    token, ttl = create_access_token(user_id, session_id)
    claims = decode_access_token(token)
    assert claims.user_id == user_id and claims.session_id == session_id
    assert ttl == get_settings().access_token_ttl_s


def test_tampered_token_rejected():
    token, _ = create_access_token(uuid.uuid4(), uuid.uuid4())
    with pytest.raises(AppError) as exc:
        decode_access_token(token[:-2] + ("aa" if token[-2:] != "aa" else "bb"))
    assert exc.value.code == "INVALID_TOKEN"


def test_expired_token_rejected():
    s = get_settings()
    now = utcnow()
    token = jwt.encode(
        {"sub": str(uuid.uuid4()), "type": "access", "iss": s.jwt_issuer,
         "iat": now - timedelta(hours=2), "exp": now - timedelta(hours=1)},
        s.jwt_secret.get_secret_value(),
        algorithm="HS256",
    )
    with pytest.raises(AppError) as exc:
        decode_access_token(token)
    assert exc.value.code == "TOKEN_EXPIRED"


def test_token_signed_with_other_secret_rejected():
    now = utcnow()
    token = jwt.encode(
        {"sub": str(uuid.uuid4()), "type": "access", "iss": get_settings().jwt_issuer,
         "iat": now, "exp": now + timedelta(minutes=5)},
        "attacker-controlled-secret-attacker-controlled",
        algorithm="HS256",
    )
    with pytest.raises(AppError):
        decode_access_token(token)


def test_opaque_tokens_are_unique_and_hash_deterministically():
    a, b = new_opaque_token("rt"), new_opaque_token("rt")
    assert a != b and a.startswith("rt_")
    assert hash_opaque_token(a) == hash_opaque_token(a) != hash_opaque_token(b)
