"""Short-lived in-memory store for observations from machine clients (SUMO, cameras, sensors).

These are not registered vehicles, so they are not written to vehicle tables. They feed the
engine for a few seconds and are then forgotten. Traffic metrics derived from them are
persisted like any other metrics, tagged with their source.
"""
import uuid
from dataclasses import dataclass, field
from datetime import datetime

from traffic_engine import DetectorCount, Observation, Source

from app.models.enums import ControllerClientKind

OBSERVATION_TTL_S = 10.0
COVERAGE_TTL_S = 10.0

KIND_TO_SOURCE = {
    ControllerClientKind.SUMO_BRIDGE: Source.SUMO,
    ControllerClientKind.CAMERA: Source.CAMERA,
    ControllerClientKind.RASPBERRY_PI: Source.SENSOR,
    ControllerClientKind.OTHER: Source.SENSOR,
}


@dataclass
class _ClientFeed:
    source: Source
    scope_codes: frozenset[str]
    received_at: datetime
    observations: list[Observation] = field(default_factory=list)
    counts: list[DetectorCount] = field(default_factory=list)


class ExternalSourceStore:
    def __init__(self) -> None:
        self._feeds: dict[uuid.UUID, _ClientFeed] = {}

    def put(self, client_id: uuid.UUID, source: Source, scope_codes: frozenset[str], now: datetime,
            observations: list[Observation], counts: list[DetectorCount]) -> None:
        self._feeds[client_id] = _ClientFeed(source, scope_codes, now, observations, counts)

    def _fresh(self, now: datetime, ttl: float) -> list[_ClientFeed]:
        return [f for f in self._feeds.values() if (now - f.received_at).total_seconds() <= ttl]

    def observations(self, now: datetime) -> list[Observation]:
        return [o for f in self._fresh(now, OBSERVATION_TTL_S) for o in f.observations]

    def counts(self, now: datetime) -> list[DetectorCount]:
        return [c for f in self._fresh(now, OBSERVATION_TTL_S) for c in f.counts]

    def fully_observed_codes(self, now: datetime) -> set[str]:
        """Intersections inside a simulator's world, where 'no vehicles' really means empty."""
        codes: set[str] = set()
        for feed in self._fresh(now, COVERAGE_TTL_S):
            if feed.source.observes_all_vehicles:
                codes |= feed.scope_codes
        return codes

    def active_sources(self, now: datetime) -> list[str]:
        return sorted({f.source.value for f in self._fresh(now, COVERAGE_TTL_S)})

    def reset(self) -> None:
        self._feeds.clear()


external_store = ExternalSourceStore()
