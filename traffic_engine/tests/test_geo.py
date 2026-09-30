import math

from traffic_engine.geo import angle_diff_deg, bearing_deg, destination, haversine_m, point_to_segment


def test_haversine_known_distance():
    # 0.0065 degrees of longitude at 31.52 N is about 617 m
    d = haversine_m(31.5204, 74.33, 31.5204, 74.3365)
    assert 610 < d < 625


def test_bearing_cardinal_directions():
    assert math.isclose(bearing_deg(31.5, 74.3, 31.5, 74.31), 90.0, abs_tol=0.1)
    assert math.isclose(bearing_deg(31.5, 74.3, 31.51, 74.3), 0.0, abs_tol=0.1)


def test_angle_diff_wraps_around_north():
    assert angle_diff_deg(350, 10) == 20
    assert angle_diff_deg(0, 180) == 180
    assert angle_diff_deg(90, 90) == 0


def test_destination_round_trip():
    lat, lon = destination(31.5204, 74.33, 45.0, 500.0)
    assert math.isclose(haversine_m(31.5204, 74.33, lat, lon), 500.0, rel_tol=1e-3)
    assert math.isclose(bearing_deg(31.5204, 74.33, lat, lon), 45.0, abs_tol=0.5)


def test_point_to_segment():
    d, t = point_to_segment(5, 3, 0, 0, 10, 0)
    assert d == 3 and t == 0.5
    d, t = point_to_segment(-4, 3, 0, 0, 10, 0)
    assert d == 5 and t == 0.0
