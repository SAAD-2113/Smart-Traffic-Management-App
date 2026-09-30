"""Seed a four-intersection corridor I1 <-> I2 <-> I3 <-> I4 with approaches and links.

The coordinates are PLACEHOLDERS on a straight east-west line. Replace them with your real
junctions (PATCH /api/v1/intersections/{id}) before collecting real data. Safe to re-run:
existing intersections, approaches and links are left untouched.

Usage: uv run python -m scripts.seed_intersections [--adaptive]
"""
import argparse
import asyncio
import math

from app.core.errors import AppError
from app.db.session import SessionLocal, engine
from app.schemas.intersection import ApproachCreate, IntersectionCreate, LinkCreate
from app.services import intersection_service

START_LAT, START_LON = 31.5204, 74.3300
SPACING_DEG_LON = 0.0065  # about 615 m at this latitude
CODES = ["I1", "I2", "I3", "I4"]


def haversine_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    r = 6_371_000.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = p2 - p1, math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(a))


async def _try(label: str, coro) -> None:
    try:
        await coro
        print(f"  created {label}")
    except AppError as exc:
        print(f"  skipped {label}: {exc.message}")


async def main(adaptive: bool) -> None:
    async with SessionLocal() as db:
        # Pass 1: intersections
        nodes = []
        for i, code in enumerate(CODES):
            node = await intersection_service.get_by_code(db, code)
            if node is None:
                node = await intersection_service.create(
                    db,
                    None,
                    IntersectionCreate(
                        code=code,
                        name=f"{code} (PLACEHOLDER - replace coordinates)",
                        latitude=START_LAT,
                        longitude=START_LON + i * SPACING_DEG_LON,
                        radius_m=40,
                        approach_radius_m=250,
                        controller_type="ADAPTIVE" if adaptive else "FIXED",
                    ),
                )
                print(f"Created intersection {code}")
            nodes.append(node)

        # Pass 2: approaches. Eastbound traffic comes from the west neighbour, and vice versa.
        for i, node in enumerate(nodes):
            west = nodes[i - 1] if i > 0 else None
            east = nodes[i + 1] if i + 1 < len(nodes) else None
            print(f"Approaches for {node.code}:")
            for name, bearing, upstream in (
                ("Eastbound", 90.0, west),
                ("Westbound", 270.0, east),
                ("Northbound", 0.0, None),
                ("Southbound", 180.0, None),
            ):
                await _try(
                    name,
                    intersection_service.add_approach(
                        db, None, node.id,
                        ApproachCreate(
                            name=name,
                            travel_bearing_deg=bearing,
                            zone_length_m=200,
                            upstream_intersection_id=upstream.id if upstream else None,
                        ),
                    ),
                )

        # Pass 3: directed links in both directions along the corridor.
        print("Links:")
        for first, second in zip(nodes, nodes[1:]):
            distance = round(haversine_m(first.latitude, first.longitude, second.latitude, second.longitude), 1)
            for src, dst, approach_name in ((first, second, "Eastbound"), (second, first, "Westbound")):
                detail = await intersection_service.get_detail(db, dst.id)
                approach = next((a for a in detail.approaches if a.name == approach_name), None)
                await _try(
                    f"{src.code} -> {dst.code} ({distance:.0f} m)",
                    intersection_service.add_link(
                        db, None, src.id,
                        LinkCreate(
                            to_intersection_id=dst.id,
                            to_approach_id=approach.id if approach else None,
                            distance_m=distance,
                        ),
                    ),
                )
    await engine.dispose()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Seed the I1-I4 placeholder corridor.")
    parser.add_argument("--adaptive", action="store_true",
                        help="Create the intersections in ADAPTIVE mode (advisory decisions from the engine).")
    asyncio.run(main(parser.parse_args().adaptive))
