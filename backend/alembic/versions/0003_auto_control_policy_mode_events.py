"""AUTO control policy (fixed-time normally, adaptive when congested) and the mode-change log.

Intersections that used ADAPTIVE become AUTO: before this release ADAPTIVE was the only way
to get congestion-responsive timing; AUTO now provides it while keeping the fixed-time plan
for normal traffic. Managers can still choose ADAPTIVE (always adaptive) or FIXED.

Revision ID: 0003
Revises: 0002
Create Date: 2026-10-04
"""
from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

import app.db.types

revision: str = '0003'
down_revision: Union[str, None] = '0002'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

CONSTRAINT = "ck_intersections_controllertype"


def upgrade() -> None:
    with op.batch_alter_table("intersections") as batch:
        batch.drop_constraint(op.f(CONSTRAINT), type_="check")
        batch.create_check_constraint(op.f(CONSTRAINT), "controller_type IN ('AUTO', 'FIXED', 'ADAPTIVE')")
    op.execute("UPDATE intersections SET controller_type = 'AUTO' WHERE controller_type = 'ADAPTIVE'")

    op.create_table(
        "signal_mode_events",
        sa.Column("id", sa.BigInteger().with_variant(sa.Integer(), "sqlite"), autoincrement=True, nullable=False),
        sa.Column("intersection_id", sa.Uuid(), nullable=False),
        sa.Column("at", app.db.types.UTCDateTime(timezone=True), nullable=False),
        sa.Column("policy", sa.String(length=16), nullable=False),
        sa.Column("from_mode", sa.String(length=32), nullable=False),
        sa.Column("to_mode", sa.String(length=32), nullable=False),
        sa.Column("reason", sa.String(length=32), nullable=False),
        sa.Column("headline", sa.String(length=120), nullable=False),
        sa.Column("detail", sa.Text(), nullable=False),
        sa.Column("traffic", sa.JSON().with_variant(postgresql.JSONB(astext_type=sa.Text()), "postgresql"), nullable=False),
        sa.ForeignKeyConstraint(["intersection_id"], ["intersections.id"],
                                name=op.f("fk_signal_mode_events_intersection_id_intersections"), ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_signal_mode_events")),
    )
    op.create_index("ix_signal_mode_events_intersection_at", "signal_mode_events", ["intersection_id", "at"])


def downgrade() -> None:
    op.drop_index("ix_signal_mode_events_intersection_at", table_name="signal_mode_events")
    op.drop_table("signal_mode_events")
    op.execute("UPDATE intersections SET controller_type = 'ADAPTIVE' WHERE controller_type = 'AUTO'")
    with op.batch_alter_table("intersections") as batch:
        batch.drop_constraint(op.f(CONSTRAINT), type_="check")
        batch.create_check_constraint(op.f(CONSTRAINT), "controller_type IN ('FIXED', 'ADAPTIVE')")
