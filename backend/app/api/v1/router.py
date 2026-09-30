from fastapi import APIRouter

from app.api.v1 import (
    admin,
    auth,
    controller,
    demo,
    driver,
    health,
    intersections,
    live,
    manager,
    me,
    signals,
    traffic,
    vehicles,
)

api_router = APIRouter()
for module in (
    health, auth, me, vehicles, driver, manager, intersections, signals, traffic, live, demo, admin, controller
):
    api_router.include_router(module.router)
