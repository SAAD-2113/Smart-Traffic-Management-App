import re
import uuid

from fastapi import Request

_VALID_REQUEST_ID = re.compile(r"[A-Za-z0-9-]{1,64}")


async def request_id_middleware(request: Request, call_next):
    """Attach a request id to every request/response so errors can be traced in the logs."""
    incoming = request.headers.get("X-Request-ID", "")
    request_id = incoming if _VALID_REQUEST_ID.fullmatch(incoming) else uuid.uuid4().hex
    request.state.request_id = request_id
    response = await call_next(request)
    response.headers["X-Request-ID"] = request_id
    return response
