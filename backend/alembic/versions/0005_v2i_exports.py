"""Digital V2I: server copies of exported CSV / log files.

Revision ID: 0005
Revises: 0004
Create Date: 2026-11-22
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

import app.db.types

revision: str = '0005'
down_revision: Union[str, None] = '0004'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "v2i_exports",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("session_id", sa.Uuid(), nullable=False),
        sa.Column("uploaded_by", sa.Uuid(), nullable=True),
        sa.Column("filename", sa.String(length=120), nullable=False),
        sa.Column("content_type", sa.String(length=40), nullable=False),
        sa.Column("size", sa.Integer(), nullable=False),
        sa.Column("content", sa.Text(), nullable=False),
        sa.Column("created_at", app.db.types.UTCDateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["session_id"], ["v2i_sessions.id"], name=op.f("fk_v2i_exports_session_id_v2i_sessions"),
                                ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["uploaded_by"], ["users.id"], name=op.f("fk_v2i_exports_uploaded_by_users"),
                                ondelete="SET NULL"),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_v2i_exports")),
    )
    op.create_index("ix_v2i_exports_session_created", "v2i_exports", ["session_id", "created_at"])


def downgrade() -> None:
    op.drop_index("ix_v2i_exports_session_created", table_name="v2i_exports")
    op.drop_table("v2i_exports")
