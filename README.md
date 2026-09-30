# Smart Traffic Management System

Final-year project: smartphone vehicle telemetry feeding a multi-intersection adaptive
traffic management engine, with SUMO simulation and Raspberry Pi intersection controllers.

| Folder | Contents | Status |
|---|---|---|
| `backend/` | FastAPI service: auth, roles, vehicles, devices, intersections, controller keys | Phase 2 |
| `infra/` | Docker Compose for PostgreSQL (+PostGIS) | Phase 2 |
| `docs/adr/` | Architecture decision records | Ongoing |
| `traffic_engine/` | Pure-Python traffic analysis and control package | Phase 6-7 |
| `sumo_bridge/` | TraCI bridge between SUMO and the engine | Phase 8 |
| `simulator/` | Demo fleet generator | Phase 4 |
| `mobile/` | Flutter driver and manager apps | Phase 3-4 |

Start with `backend/README.md`.
