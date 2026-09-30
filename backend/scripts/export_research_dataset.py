"""Export an anonymised telemetry dataset for research (CSV).

What is removed or transformed:
- vehicle ids and codes are replaced by random pseudonyms that differ on every export,
  so two exports cannot be joined to follow one vehicle over a longer period;
- owner identity, registration numbers, device and session ids are never read;
- timestamps are rounded to --time-resolution seconds;
- coordinates are rounded to --decimals decimal places (4 decimals is about 11 m);
- trips shorter than --min-points are dropped (short trips are easier to re-identify);
- simulated vehicles are excluded unless --include-simulated is given.

Usage (from the backend folder):
    uv run python -m scripts.export_research_dataset --hours 24 --out research.csv
"""
import argparse
import asyncio
import csv
import secrets
import sys
from collections import defaultdict
from datetime import datetime, timedelta, timezone

from sqlalchemy import select

from app.core.time import utcnow
from app.db.session import SessionLocal, engine
from app.models.telemetry import VehicleTelemetry
from app.models.vehicle import Vehicle


def _round_time(value: datetime, resolution_s: int) -> str:
    epoch = int(value.timestamp()) // resolution_s * resolution_s
    return datetime.fromtimestamp(epoch, tz=timezone.utc).isoformat()


async def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--hours", type=float, default=24.0)
    parser.add_argument("--out", required=True)
    parser.add_argument("--decimals", type=int, default=4, choices=range(3, 7))
    parser.add_argument("--time-resolution", type=int, default=1)
    parser.add_argument("--min-points", type=int, default=30)
    parser.add_argument("--include-simulated", action="store_true")
    args = parser.parse_args()

    since = utcnow() - timedelta(hours=args.hours)
    async with SessionLocal() as db:
        stmt = (
            select(VehicleTelemetry, Vehicle.vehicle_type, Vehicle.is_simulated)
            .join(Vehicle, Vehicle.id == VehicleTelemetry.vehicle_id)
            .where(VehicleTelemetry.recorded_at >= since, VehicleTelemetry.usable.is_(True))
            .order_by(VehicleTelemetry.vehicle_id, VehicleTelemetry.recorded_at)
        )
        if not args.include_simulated:
            stmt = stmt.where(Vehicle.is_simulated.is_(False))
        rows = (await db.execute(stmt)).all()
    await engine.dispose()

    trips: dict[object, list] = defaultdict(list)
    for t, vehicle_type, is_simulated in rows:
        trips[(t.vehicle_id, t.session_id)].append((t, vehicle_type, is_simulated))

    written = 0
    with open(args.out, "w", newline="", encoding="utf-8") as fh:
        writer = csv.writer(fh)
        writer.writerow(["trip", "time_utc", "lat", "lon", "speed_mps", "heading_deg", "accuracy_m",
                         "vehicle_class", "emergency", "zone", "simulated"])
        for points in trips.values():
            if len(points) < args.min_points:
                continue
            pseudonym = secrets.token_hex(6)
            for t, vehicle_type, is_simulated in points:
                writer.writerow([
                    pseudonym, _round_time(t.recorded_at, args.time_resolution),
                    round(t.lat, args.decimals), round(t.lon, args.decimals),
                    None if t.speed_mps is None else round(t.speed_mps, 1),
                    None if t.heading_deg is None else round(t.heading_deg),
                    round(t.accuracy_m), "EMERGENCY" if vehicle_type.is_emergency else "GENERAL",
                    t.emergency, t.zone.value if t.zone else "", is_simulated,
                ])
                written += 1
    print(f"Wrote {written} points from {sum(1 for p in trips.values() if len(p) >= args.min_points)} trips to {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
