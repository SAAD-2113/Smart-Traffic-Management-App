"""Digital V2I: per-account V2I profile (vehicle id, emergency authorisation), sessions with a
join code, and session members.

Revision ID: 0004
Revises: 0003
Create Date: 2026-11-22
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

import app.db.types

revision: str = '0004'
down_revision: Union[str, None] = '0003'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

EMERGENCY = ("NONE", "REQUESTED", "APPROVED", "REJECTED", "REVOKED")
SESSION = ("OPEN", "CLOSED")


def _in(column: str, values: tuple[str, ...]) -> str:
    return f"{column} IN ({', '.join(repr(v) for v in values)})"


def upgrade() -> None:
    op.create_table(
        "v2i_profiles",
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("vehicle_id", sa.Integer(), nullable=False),
        sa.Column("emergency_status", sa.String(length=32), nullable=False),
        sa.Column("emergency_reason", sa.String(length=200), nullable=True),
        sa.Column("emergency_requested_at", app.db.types.UTCDateTime(timezone=True), nullable=True),
        sa.Column("emergency_decided_at", app.db.types.UTCDateTime(timezone=True), nullable=True),
        sa.Column("emergency_decided_by", sa.Uuid(), nullable=True),
        sa.Column("created_at", app.db.types.UTCDateTime(timezone=True), nullable=False),
        sa.Column("updated_at", app.db.types.UTCDateTime(timezone=True), nullable=False),
        sa.CheckConstraint(_in("emergency_status", EMERGENCY), name=op.f("ck_v2i_profiles_v2iemergencystatus")),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], name=op.f("fk_v2i_profiles_user_id_users"), ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["emergency_decided_by"], ["users.id"],
                                name=op.f("fk_v2i_profiles_emergency_decided_by_users"), ondelete="SET NULL"),
        sa.PrimaryKeyConstraint("user_id", name=op.f("pk_v2i_profiles")),
        sa.UniqueConstraint("vehicle_id", name=op.f("uq_v2i_profiles_vehicle_id")),
    )
    op.create_table(
        "v2i_sessions",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("name", sa.String(length=60), nullable=False),
        sa.Column("join_code", sa.String(length=8), nullable=False),
        sa.Column("host_user_id", sa.Uuid(), nullable=False),
        sa.Column("center_lat", sa.Float(), nullable=False),
        sa.Column("center_lon", sa.Float(), nullable=False),
        sa.Column("status", sa.String(length=32), nullable=False),
        sa.Column("created_at", app.db.types.UTCDateTime(timezone=True), nullable=False),
        sa.Column("closed_at", app.db.types.UTCDateTime(timezone=True), nullable=True),
        sa.CheckConstraint(_in("status", SESSION), name=op.f("ck_v2i_sessions_v2isessionstatus")),
        sa.ForeignKeyConstraint(["host_user_id"], ["users.id"], name=op.f("fk_v2i_sessions_host_user_id_users"),
                                ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_v2i_sessions")),
        sa.UniqueConstraint("join_code", name=op.f("uq_v2i_sessions_join_code")),
    )
    op.create_index("ix_v2i_sessions_host_status", "v2i_sessions", ["host_user_id", "status"])
    op.create_table(
        "v2i_members",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("session_id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("joined_at", app.db.types.UTCDateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["session_id"], ["v2i_sessions.id"], name=op.f("fk_v2i_members_session_id_v2i_sessions"),
                                ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], name=op.f("fk_v2i_members_user_id_users"), ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_v2i_members")),
        sa.UniqueConstraint("session_id", "user_id", name=op.f("uq_v2i_members_session_id_user_id")),
    )
    op.create_index(op.f("ix_v2i_members_user_id"), "v2i_members", ["user_id"])


def downgrade() -> None:
    op.drop_index(op.f("ix_v2i_members_user_id"), table_name="v2i_members")
    op.drop_table("v2i_members")
    op.drop_index("ix_v2i_sessions_host_status", table_name="v2i_sessions")
    op.drop_table("v2i_sessions")
    op.drop_table("v2i_profiles")
