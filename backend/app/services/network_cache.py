"""Builds the engine's Network from the intersection tables, cached briefly in memory.

Intersection edits call invalidate(), so changes apply at the next engine cycle.
"""
import time
import uuid
from dataclasses import dataclass, field

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from traffic_engine import ApproachGeometry, IntersectionGeometry, LinkGeometry, Network

from app.models.enums import ActuatorType, ControllerType, IntersectionStatus
from app.models.intersection import Intersection, IntersectionApproach, IntersectionLink

CACHE_TTL_S = 30.0


@dataclass(frozen=True)
class IntersectionInfo:
    id: uuid.UUID
    code: str
    name: str
    status: IntersectionStatus
    controller_type: ControllerType
    actuator: ActuatorType
    latitude: float
    longitude: float
    radius_m: float
    approach_radius_m: float
    penetration_rate: float
    sumo_tls_id: str | None


@dataclass
class NetworkRefs:
    """Maps engine identifiers (codes and names) back to database ids."""

    by_code: dict[str, IntersectionInfo] = field(default_factory=dict)
    by_id: dict[uuid.UUID, IntersectionInfo] = field(default_factory=dict)
    approach_ids: dict[tuple[str, str], uuid.UUID] = field(default_factory=dict)
    approach_names: dict[uuid.UUID, str] = field(default_factory=dict)


_cache: tuple[float, Network, NetworkRefs] | None = None


def invalidate() -> None:
    global _cache
    _cache = None


async def load(db: AsyncSession, *, use_cache: bool = True) -> tuple[Network, NetworkRefs]:
    global _cache
    if use_cache and _cache is not None and time.monotonic() - _cache[0] < CACHE_TTL_S:
        return _cache[1], _cache[2]

    intersections = list(await db.scalars(select(Intersection).order_by(Intersection.code)))
    approaches = list(await db.scalars(select(IntersectionApproach)))
    links = list(await db.scalars(select(IntersectionLink)))

    refs = NetworkRefs()
    code_of: dict[uuid.UUID, str] = {}
    for i in intersections:
        info = IntersectionInfo(
            id=i.id, code=i.code, name=i.name, status=i.status, controller_type=i.controller_type,
            actuator=i.actuator, latitude=i.latitude, longitude=i.longitude, radius_m=i.radius_m,
            approach_radius_m=i.approach_radius_m, penetration_rate=i.assumed_penetration_rate,
            sumo_tls_id=i.sumo_tls_id,
        )
        refs.by_code[i.code] = info
        refs.by_id[i.id] = info
        code_of[i.id] = i.code

    approaches_by_node: dict[uuid.UUID, list[ApproachGeometry]] = {}
    approach_name_by_id: dict[uuid.UUID, str] = {}
    for a in sorted(approaches, key=lambda a: a.name):
        approach_name_by_id[a.id] = a.name
        refs.approach_ids[(code_of[a.intersection_id], a.name)] = a.id
        refs.approach_names[a.id] = a.name
        approaches_by_node.setdefault(a.intersection_id, []).append(
            ApproachGeometry(
                name=a.name,
                travel_bearing_deg=a.travel_bearing_deg,
                bearing_tolerance_deg=a.bearing_tolerance_deg,
                lanes=a.lanes,
                zone_length_m=a.zone_length_m,
                free_flow_speed_mps=a.free_flow_speed_mps,
                upstream_code=code_of.get(a.upstream_intersection_id) if a.upstream_intersection_id else None,
            )
        )

    nodes = {
        i.code: IntersectionGeometry(
            code=i.code, name=i.name, lat=i.latitude, lon=i.longitude, radius_m=i.radius_m,
            approach_radius_m=i.approach_radius_m, penetration_rate=i.assumed_penetration_rate,
            approaches=tuple(approaches_by_node.get(i.id, [])),
            active=i.status == IntersectionStatus.ACTIVE, ref=str(i.id),
        )
        for i in intersections
    }
    engine_links = [
        LinkGeometry(
            id=str(link.id), from_code=code_of[link.from_intersection_id], to_code=code_of[link.to_intersection_id],
            distance_m=link.distance_m, free_flow_speed_mps=link.free_flow_speed_mps,
            to_approach_name=approach_name_by_id.get(link.to_approach_id) if link.to_approach_id else None,
        )
        for link in links
    ]
    network = Network(intersections=nodes, links=engine_links)
    _cache = (time.monotonic(), network, refs)
    return network, refs
