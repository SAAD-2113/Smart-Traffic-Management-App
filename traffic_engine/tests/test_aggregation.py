from datetime import timedelta

from traffic_engine.aggregation import StopTracker, aggregate, classify_congestion
from traffic_engine.mapping import map_observation
from traffic_engine.model import CongestionLevel, DataQuality, DetectorCount, Observation, Source

from tests.conftest import NOW, build_corridor, offset


def queue(network, code, n, *, source=Source.SIMULATOR, speed=0.0, start=50.0, prefix="q"):
    """n vehicles queued on the Eastbound approach of `code`, 7 m apart."""
    result = []
    for i in range(n):
        lat, lon = offset(code, network, 270.0, start + 7.0 * i)
        result.append(Observation(key=f"{prefix}{i}", source=source, lat=lat, lon=lon, recorded_at=NOW,
                                  accuracy_m=4.0, speed_mps=speed, heading_deg=None if speed < 1 else 90.0))
    return result


def run(network, observations, tracker=None, now=NOW, **kw):
    mapped = [map_observation(o, network) for o in observations]
    return aggregate(mapped, network, now, tracker if tracker is not None else StopTracker(), **kw)


def test_no_data_is_unknown_not_free_flow(corridor):
    metrics = run(corridor, [])
    for m in metrics.values():
        assert m.congestion_level == CongestionLevel.UNKNOWN
        assert m.data_quality == DataQuality.NONE
        assert m.estimated_vehicle_count is None


def test_fully_observed_empty_intersection_is_low(corridor):
    metrics = run(corridor, [], fully_observed_codes={"I1"})
    assert metrics["I1"].congestion_level == CongestionLevel.LOW
    assert metrics["I1"].data_quality == DataQuality.HIGH
    assert metrics["I2"].congestion_level == CongestionLevel.UNKNOWN


def test_stopped_queue_is_severe_with_observed_stats(corridor):
    metrics = run(corridor, queue(corridor, "I1", 8))
    east = next(a for a in metrics["I1"].approaches if a.approach_name == "Eastbound")
    assert east.observed.vehicle_count == 8
    assert east.observed.stopped_count == 8
    assert east.observed.avg_speed_mps == 0.0
    assert east.estimated_vehicle_count == 8  # simulator sees every vehicle: no scaling
    assert east.congestion_level == CongestionLevel.SEVERE
    assert metrics["I1"].observed.vehicle_count == 8


def test_single_phone_is_scaled_but_low_quality(corridor):
    probe = queue(corridor, "I2", 1, source=Source.MOBILE, speed=10.0)
    metrics = run(corridor, probe)
    east = next(a for a in metrics["I2"].approaches if a.approach_name == "Eastbound")
    assert east.data_quality == DataQuality.LOW
    assert east.estimated_vehicle_count == 20  # 1 / 0.05
    # density class ignored at LOW quality: speed 10/11.1 → LOW, not SEVERE
    assert east.congestion_level == CongestionLevel.LOW


def test_waiting_time_accumulates_across_cycles(corridor):
    tracker = StopTracker()
    vehicles = queue(corridor, "I3", 3)
    run(corridor, vehicles, tracker, now=NOW)
    later = NOW + timedelta(seconds=20)
    shifted = [Observation(**{**o.__dict__, "recorded_at": later}) for o in vehicles]
    metrics = run(corridor, shifted, tracker, now=later)
    east = next(a for a in metrics["I3"].approaches if a.approach_name == "Eastbound")
    assert east.avg_waiting_time_s == 20.0
    assert metrics["I3"].avg_waiting_time_s == 20.0


def test_moving_vehicle_resets_waiting_time(corridor):
    tracker = StopTracker()
    run(corridor, queue(corridor, "I3", 1), tracker, now=NOW)
    moving = queue(corridor, "I3", 1, speed=8.0)
    later = NOW + timedelta(seconds=10)
    metrics = run(corridor, [Observation(**{**moving[0].__dict__, "recorded_at": later})], tracker, now=later)
    east = next(a for a in metrics["I3"].approaches if a.approach_name == "Eastbound")
    assert east.avg_waiting_time_s is None
    assert len(tracker) == 0


def test_detector_counts_are_not_scaled(corridor):
    count = DetectorCount("I4", "Northbound", 12, NOW)
    metrics = run(corridor, [], detector_counts=[count])
    north = next(a for a in metrics["I4"].approaches if a.approach_name == "Northbound")
    assert north.detector_count == 12 and north.estimated_vehicle_count == 12
    assert north.data_quality == DataQuality.HIGH


def test_classify_congestion_thresholds():
    assert classify_congestion(0.9, 5, DataQuality.HIGH, 3) == CongestionLevel.LOW
    assert classify_congestion(0.5, 5, DataQuality.HIGH, 3) == CongestionLevel.MODERATE
    assert classify_congestion(0.9, 40, DataQuality.HIGH, 3) == CongestionLevel.HIGH
    assert classify_congestion(0.1, 5, DataQuality.HIGH, 3) == CongestionLevel.SEVERE
    assert classify_congestion(0.9, 90, DataQuality.LOW, 1) == CongestionLevel.LOW
    assert classify_congestion(None, None, DataQuality.NONE, 0) == CongestionLevel.UNKNOWN


def test_penetration_rate_is_per_intersection():
    network = build_corridor(penetration=0.25)
    metrics = run(network, queue(network, "I1", 1, source=Source.MOBILE, speed=5.0))
    east = next(a for a in metrics["I1"].approaches if a.approach_name == "Eastbound")
    assert east.estimated_vehicle_count == 4
