from datetime import timedelta

from tests.conftest import NOW, offset
from traffic_engine.mapping import map_observation
from traffic_engine.model import Observation, Source, Zone


def obs(lat, lon, *, speed=10.0, heading=90.0, key="v1", source=Source.MOBILE, emergency=False):
    return Observation(key=key, source=source, lat=lat, lon=lon, recorded_at=NOW - timedelta(seconds=1),
                       accuracy_m=5.0, speed_mps=speed, heading_deg=heading, emergency=emergency)


def test_vehicle_heading_into_junction_is_on_matching_approach(corridor):
    lat, lon = offset("I2", corridor, 270.0, 120.0)  # 120 m west of I2
    m = map_observation(obs(lat, lon, heading=90.0), corridor)
    assert (m.intersection_code, m.zone, m.approach_name) == ("I2", Zone.APPROACH, "Eastbound")
    assert 110 < m.distance_to_centre_m < 130
    assert 11 < m.eta_s < 13


def test_vehicle_in_junction_box_is_core(corridor):
    lat, lon = offset("I3", corridor, 0.0, 15.0)
    m = map_observation(obs(lat, lon), corridor)
    assert (m.intersection_code, m.zone) == ("I3", Zone.CORE)


def test_vehicle_leaving_is_departure_and_on_the_next_link(corridor):
    lat, lon = offset("I2", corridor, 90.0, 120.0)  # east of I2, heading east towards I3
    m = map_observation(obs(lat, lon, heading=90.0), corridor)
    assert (m.intersection_code, m.zone) == ("I2", Zone.DEPARTURE)
    assert m.link_id == "I2-I3" and m.link_to_approach == "Eastbound"
    assert 480 < m.distance_to_next_m < 520


def test_stationary_vehicle_uses_bearing_to_centre(corridor):
    lat, lon = offset("I1", corridor, 180.0, 60.0)  # south of I1, stopped, heading unknown
    m = map_observation(obs(lat, lon, speed=0.0, heading=None), corridor)
    assert (m.zone, m.approach_name) == (Zone.APPROACH, "Northbound")


def test_heading_ignored_when_nearly_stopped(corridor):
    lat, lon = offset("I1", corridor, 180.0, 60.0)
    m = map_observation(obs(lat, lon, speed=0.3, heading=270.0), corridor)  # noisy heading
    assert m.approach_name == "Northbound"


def test_far_away_vehicle_is_unmapped(corridor):
    lat, lon = offset("I1", corridor, 0.0, 3000.0)
    m = map_observation(obs(lat, lon), corridor)
    assert m.intersection_code is None and m.zone is None and m.link_id is None


def test_vehicle_between_junctions_is_on_link_with_eta(corridor):
    lat, lon = offset("I1", corridor, 90.0, 300.0)  # beyond both approach radii
    m = map_observation(obs(lat, lon, speed=10.0, heading=90.0), corridor)
    assert m.zone == Zone.ON_LINK and m.intersection_code is None
    assert m.link_id == "I1-I2" and m.link_to_code == "I2"
    assert 290 < m.distance_to_next_m < 330
    assert 29 < m.eta_s < 33


def test_link_direction_must_match(corridor):
    lat, lon = offset("I1", corridor, 90.0, 300.0)
    m = map_observation(obs(lat, lon, speed=10.0, heading=270.0), corridor)
    assert m.link_id == "I2-I1"
