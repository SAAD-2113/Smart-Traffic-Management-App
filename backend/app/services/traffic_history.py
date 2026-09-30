"""Traffic history from the periodic metric snapshots, bucketed for charts."""
import uuid
from collections import defaultdict
from datetime import datetime, timedelta, timezone

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.errors import not_found
from app.core.time import utcnow
from app.models.intersection import Intersection
from app.models.traffic import TrafficMetric
from app.schemas.traffic import HistoryPointOut, IntersectionHistoryOut, NetworkHistoryOut

RANK = {"LOW": 0, "MODERATE": 1, "HIGH": 2, "SEVERE": 3}


def _mean(values: list[float]) -> float | None:
    return round(sum(values) / len(values), 2) if values else None


def _bucketize(rows: list[TrafficMetric], bucket_s: int) -> list[HistoryPointOut]:
    buckets: dict[int, list[TrafficMetric]] = defaultdict(list)
    for r in rows:
        buckets[int(r.window_end.timestamp()) // bucket_s].append(r)
    points = []
    for key in sorted(buckets):
        group = buckets[key]
        ranks = [RANK[r.congestion_level] for r in group if r.congestion_level in RANK]
        worst = max(group, key=lambda r: RANK.get(r.congestion_level, -1)).congestion_level
        estimates = [r.est_vehicle_count for r in group if r.est_vehicle_count is not None]
        points.append(HistoryPointOut(
            t=datetime.fromtimestamp(key * bucket_s, tz=timezone.utc),
            # Snapshots without any data say nothing about traffic: a gap, not zero vehicles.
            observed_vehicles=_mean([float(r.observed_vehicle_count) for r in group if r.data_quality != "NONE"]),
            estimated_vehicles=_mean(estimates),
            avg_speed_mps=_mean([r.observed_avg_speed_mps for r in group if r.observed_avg_speed_mps is not None]),
            avg_waiting_time_s=_mean([r.calc_avg_waiting_time_s for r in group if r.calc_avg_waiting_time_s is not None]),
            congestion_rank=_mean(ranks),
            worst_congestion=worst,
            emergency_count=max(r.observed_emergency_count for r in group),
        ))
    return points


async def _rows(db: AsyncSession, since: datetime, intersection_id: uuid.UUID | None = None) -> list[TrafficMetric]:
    stmt = (
        select(TrafficMetric)
        .where(TrafficMetric.approach_id.is_(None), TrafficMetric.window_end >= since)
        .order_by(TrafficMetric.window_end)
    )
    if intersection_id is not None:
        stmt = stmt.where(TrafficMetric.intersection_id == intersection_id)
    return list(await db.scalars(stmt))


async def intersection_history(db: AsyncSession, intersection_id: uuid.UUID, hours: float, bucket_s: int) -> IntersectionHistoryOut:
    intersection = await db.get(Intersection, intersection_id)
    if intersection is None:
        raise not_found("Intersection")
    rows = await _rows(db, utcnow() - timedelta(hours=hours), intersection.id)
    return IntersectionHistoryOut(intersection_id=intersection.id, code=intersection.code, bucket_s=bucket_s,
                                  points=_bucketize(rows, bucket_s))


async def network_history(db: AsyncSession, hours: float, bucket_s: int) -> NetworkHistoryOut:
    rows = await _rows(db, utcnow() - timedelta(hours=hours))
    intersections = {i.id: i for i in await db.scalars(select(Intersection).order_by(Intersection.code))}
    by_node: dict[uuid.UUID, list[TrafficMetric]] = defaultdict(list)
    for r in rows:
        by_node[r.intersection_id].append(r)
    return NetworkHistoryOut(
        bucket_s=bucket_s,
        series=[
            IntersectionHistoryOut(intersection_id=i.id, code=i.code, bucket_s=bucket_s,
                                   points=_bucketize(by_node.get(i.id, []), bucket_s))
            for i in intersections.values()
        ],
    )
