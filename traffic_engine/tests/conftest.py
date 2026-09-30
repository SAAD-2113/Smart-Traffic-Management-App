from datetime import datetime, timezone

import pytest

from traffic_engine.geo import destination, haversine_m
from traffic_engine.model import ApproachGeometry, IntersectionGeometry, LinkGeometry, Network

LAT, LON0, SPACING = 31.5204, 74.3300, 0.0065
NOW = datetime(2026, 9, 30, 12, 0, 0, tzinfo=timezone.utc)


def build_corridor(n: int = 4, penetration: float = 0.05) -> Network:
    codes = [f"I{i + 1}" for i in range(n)]
    nodes = {}
    for i, code in enumerate(codes):
        west = codes[i - 1] if i > 0 else None
        east = codes[i + 1] if i + 1 < n else None
        nodes[code] = IntersectionGeometry(
            code=code, name=code, lat=LAT, lon=LON0 + i * SPACING, radius_m=40, approach_radius_m=250,
            penetration_rate=penetration,
            approaches=(
                ApproachGeometry("Eastbound", 90.0, zone_length_m=200, upstream_code=west),
                ApproachGeometry("Westbound", 270.0, zone_length_m=200, upstream_code=east),
                ApproachGeometry("Northbound", 0.0, zone_length_m=200),
                ApproachGeometry("Southbound", 180.0, zone_length_m=200),
            ),
        )
    links = []
    for a, b in zip(codes, codes[1:]):
        d = haversine_m(nodes[a].lat, nodes[a].lon, nodes[b].lat, nodes[b].lon)
        links.append(LinkGeometry(f"{a}-{b}", a, b, d, to_approach_name="Eastbound"))
        links.append(LinkGeometry(f"{b}-{a}", b, a, d, to_approach_name="Westbound"))
    return Network(intersections=nodes, links=links)


def offset(code: str, network: Network, bearing: float, distance: float) -> tuple[float, float]:
    node = network.intersections[code]
    return destination(node.lat, node.lon, bearing, distance)


@pytest.fixture
def corridor() -> Network:
    return build_corridor()
