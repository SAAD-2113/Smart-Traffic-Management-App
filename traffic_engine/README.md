# traffic_engine

Pure-Python traffic analysis and advisory signal-control library. It has no web, database or
SUMO dependency, so the backend, the SUMO bridge and offline experiments can all import it.

```text
Observation (mobile / simulator / SUMO / camera)
   → mapping.map_observation        vehicle → intersection zone, approach, link, ETA
   → aggregation.aggregate          observed → calculated → estimated metrics
   → network.build_network_state    upstream arrivals, downstream load, emergencies
   → control.*Controller.decide     advisory SignalDecision (validUntil)
```

| Module | Purpose |
|---|---|
| `geo` | Haversine distance, bearings, local projection, point-to-segment |
| `model` | Input types: `Observation`, `DetectorCount`, network geometry |
| `mapping` | Zone (CORE / APPROACH / DEPARTURE / ON_LINK), approach and link matching |
| `aggregation` | Per-approach and per-intersection metrics, stop tracking, congestion classes |
| `network` | Network-wide state for coordination between intersections |
| `control` | `SignalPlan`, `SignalDecision`, `SignalController` protocol, fixed / Webster-style / emergency-priority controllers |
| `simulation` | Demo fleet (IDM car following) and virtual signals that execute decisions |
| `engine` | `TrafficEngine.run_cycle()` ties the steps together |

Run the tests: `uv run --group dev pytest` (from this folder).

All units are SI: metres, m/s, degrees, seconds, UTC datetimes.
