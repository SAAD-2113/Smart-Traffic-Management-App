import uuid

from sqlalchemy import CheckConstraint, Float, ForeignKey, Integer, String, UniqueConstraint, Uuid
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db.base import Base, TimestampMixin
from app.db.types import enum_column
from app.models.enums import ActuatorType, ControllerType, IntersectionStatus


class Intersection(TimestampMixin, Base):
    __tablename__ = "intersections"
    __table_args__ = (
        CheckConstraint("latitude BETWEEN -90 AND 90", name="latitude_range"),
        CheckConstraint("longitude BETWEEN -180 AND 180", name="longitude_range"),
        CheckConstraint("radius_m > 0", name="radius_positive"),
        CheckConstraint("approach_radius_m > radius_m", name="approach_outside_core"),
        CheckConstraint(
            "assumed_penetration_rate > 0 AND assumed_penetration_rate <= 1",
            name="penetration_range",
        ),
    )

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)
    code: Mapped[str] = mapped_column(String(16), unique=True, nullable=False)  # "I1"
    name: Mapped[str] = mapped_column(String(120), nullable=False)
    latitude: Mapped[float] = mapped_column(Float, nullable=False)
    longitude: Mapped[float] = mapped_column(Float, nullable=False)
    radius_m: Mapped[float] = mapped_column(Float, nullable=False)
    approach_radius_m: Mapped[float] = mapped_column(Float, nullable=False)
    status: Mapped[IntersectionStatus] = mapped_column(
        enum_column(IntersectionStatus), nullable=False, default=IntersectionStatus.ACTIVE
    )
    controller_type: Mapped[ControllerType] = mapped_column(
        enum_column(ControllerType), nullable=False, default=ControllerType.AUTO
    )
    actuator: Mapped[ActuatorType] = mapped_column(
        enum_column(ActuatorType), nullable=False, default=ActuatorType.DISPLAY_ONLY
    )
    sumo_tls_id: Mapped[str | None] = mapped_column(String(64))
    # Share of vehicles assumed to run the app; used later to scale observed counts (an estimate).
    assumed_penetration_rate: Mapped[float] = mapped_column(Float, nullable=False, default=0.05)

    approaches: Mapped[list["IntersectionApproach"]] = relationship(
        back_populates="intersection",
        foreign_keys="IntersectionApproach.intersection_id",
        cascade="all, delete-orphan",
        order_by="IntersectionApproach.name",
        lazy="raise",
    )


class IntersectionApproach(Base):
    """One direction of travel into an intersection (e.g. vehicles heading east into I2)."""

    __tablename__ = "intersection_approaches"
    __table_args__ = (
        UniqueConstraint("intersection_id", "name"),
        CheckConstraint("travel_bearing_deg >= 0 AND travel_bearing_deg < 360", name="bearing_range"),
        CheckConstraint("bearing_tolerance_deg > 0 AND bearing_tolerance_deg <= 90", name="tolerance_range"),
        CheckConstraint("lanes >= 1", name="lanes_positive"),
        CheckConstraint("zone_length_m > 0", name="zone_positive"),
        CheckConstraint("free_flow_speed_mps > 0", name="free_flow_positive"),
    )

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)
    intersection_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("intersections.id", ondelete="CASCADE"), index=True, nullable=False
    )
    name: Mapped[str] = mapped_column(String(40), nullable=False)
    travel_bearing_deg: Mapped[float] = mapped_column(Float, nullable=False)
    bearing_tolerance_deg: Mapped[float] = mapped_column(Float, nullable=False, default=45.0)
    lanes: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    zone_length_m: Mapped[float] = mapped_column(Float, nullable=False)
    free_flow_speed_mps: Mapped[float] = mapped_column(Float, nullable=False, default=11.1)
    upstream_intersection_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("intersections.id", ondelete="SET NULL")
    )

    intersection: Mapped[Intersection] = relationship(
        back_populates="approaches", foreign_keys=[intersection_id], lazy="raise"
    )


class IntersectionLink(Base):
    """Directed road segment between two intersections (I1 -> I2). Forms the corridor graph."""

    __tablename__ = "intersection_links"
    __table_args__ = (
        UniqueConstraint("from_intersection_id", "to_intersection_id"),
        CheckConstraint("from_intersection_id <> to_intersection_id", name="no_self_link"),
        CheckConstraint("distance_m > 0", name="distance_positive"),
        CheckConstraint("free_flow_speed_mps > 0", name="free_flow_positive"),
    )

    id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True, default=uuid.uuid4)
    from_intersection_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("intersections.id", ondelete="CASCADE"), index=True, nullable=False
    )
    to_intersection_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("intersections.id", ondelete="CASCADE"), index=True, nullable=False
    )
    to_approach_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("intersection_approaches.id", ondelete="SET NULL")
    )
    distance_m: Mapped[float] = mapped_column(Float, nullable=False)
    free_flow_speed_mps: Mapped[float] = mapped_column(Float, nullable=False, default=11.1)
