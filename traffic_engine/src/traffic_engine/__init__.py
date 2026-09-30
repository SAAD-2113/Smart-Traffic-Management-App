"""Traffic analysis and advisory signal-control engine (pure Python, SI units, UTC)."""
from traffic_engine.aggregation import ApproachMetrics, IntersectionMetrics, ObservedStats, StopTracker
from traffic_engine.engine import LIVE_WINDOW_S, MAX_ACCURACY_FOR_METRICS_M, CycleResult, TrafficEngine
from traffic_engine.mapping import MappedObservation, map_observation
from traffic_engine.model import (
    ApproachGeometry,
    CongestionLevel,
    DataQuality,
    DetectorCount,
    IntersectionGeometry,
    LinkGeometry,
    Network,
    Observation,
    Source,
    Zone,
)
from traffic_engine.network import DownstreamLoad, EmergencyApproach, IntersectionState, NetworkState, UpstreamFlow

__version__ = "0.3.0"

__all__ = [
    "LIVE_WINDOW_S",
    "MAX_ACCURACY_FOR_METRICS_M",
    "ApproachGeometry",
    "ApproachMetrics",
    "CongestionLevel",
    "CycleResult",
    "DataQuality",
    "DetectorCount",
    "DownstreamLoad",
    "EmergencyApproach",
    "IntersectionGeometry",
    "IntersectionMetrics",
    "IntersectionState",
    "LinkGeometry",
    "MappedObservation",
    "Network",
    "NetworkState",
    "Observation",
    "ObservedStats",
    "Source",
    "StopTracker",
    "TrafficEngine",
    "UpstreamFlow",
    "Zone",
    "map_observation",
]
