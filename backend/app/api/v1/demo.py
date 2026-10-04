"""Demo simulation controls. Refused unless the server runs with DEMO_MODE=true."""
from fastapi import APIRouter, Depends
from sqlalchemy.ext.asyncio import async_sessionmaker

from app.api.deps import require_manager
from app.db.session import get_session_factory
from app.models.user import User
from app.schemas.demo import DemoStartRequest, DemoStatusOut, DemoSurgeRequest
from app.services.demo_service import demo

router = APIRouter(prefix="/demo", tags=["demo (simulation)"])


@router.get("/status", response_model=DemoStatusOut)
async def status(_: User = Depends(require_manager)) -> DemoStatusOut:
    return demo.status()


@router.post("/start", response_model=DemoStatusOut)
async def start(
    body: DemoStartRequest,
    user: User = Depends(require_manager),
    factory: async_sessionmaker = Depends(get_session_factory),
) -> DemoStatusOut:
    return await demo.start(factory, user, body.vehicles, body.include_emergency_vehicle, body.seed)


@router.post("/stop", response_model=DemoStatusOut)
async def stop(
    user: User = Depends(require_manager), factory: async_sessionmaker = Depends(get_session_factory)
) -> DemoStatusOut:
    return await demo.stop(factory, user)


@router.post("/surge", response_model=DemoStatusOut)
async def start_surge(
    body: DemoSurgeRequest,
    user: User = Depends(require_manager),
    factory: async_sessionmaker = Depends(get_session_factory),
) -> DemoStatusOut:
    """Simulated rush hour: most new simulated trips go through one intersection for a while."""
    return await demo.start_surge(factory, user, body.intersection_code.strip().upper(), body.duration_s)


@router.post("/surge/stop", response_model=DemoStatusOut)
async def stop_surge(_: User = Depends(require_manager)) -> DemoStatusOut:
    return demo.stop_surge()
