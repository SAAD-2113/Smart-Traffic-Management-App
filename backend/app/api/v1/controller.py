from fastapi import APIRouter, Depends

from app.api.deps import get_controller_client
from app.core.time import utcnow
from app.models.system import ControllerClient
from app.schemas.controller import ControllerPingOut

router = APIRouter(prefix="/controller", tags=["controller (machine clients)"])


@router.get("/ping", response_model=ControllerPingOut)
async def ping(client: ControllerClient = Depends(get_controller_client)) -> ControllerPingOut:
    """Lets a Raspberry Pi verify its key, its scope and its internet path to the backend."""
    return ControllerPingOut(
        client_id=client.id,
        name=client.name,
        intersection_codes=sorted(i.code for i in client.intersections),
        server_time=utcnow(),
    )
