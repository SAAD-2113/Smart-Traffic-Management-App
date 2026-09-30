from fastapi import APIRouter

from app.api.v1 import admin, auth, controller, health, intersections, manager, me, vehicles

api_router = APIRouter()
for module in (health, auth, me, vehicles, manager, intersections, admin, controller):
    api_router.include_router(module.router)
