"""HTTP surface of the broadcaster (FastAPI).

Implements the loopback control contract the Black Candy Store Rails app calls,
plus the internal MP3 fan-out endpoint Rails reverse-proxies public listeners to:

    GET    /healthz                          -> liveness
    POST   /broadcasts                       -> spin up a broadcast
    DELETE /broadcasts/{id}                  -> tear a broadcast down
    POST   /broadcasts/{id}/next             -> hand in the next resolved source
    GET    /broadcasts/{id}/status           -> encode position, listener count, uptime
    GET    /internal/broadcasts/{id}/listen  -> raw MP3 fan-out (loopback only)
"""

from __future__ import annotations

import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.responses import JSONResponse, StreamingResponse

from .broadcast import Listener
from .config import get_settings
from .errors import BroadcastAlreadyExists, BroadcastNotFound, ListenerLimitReached
from .models import BroadcastHandle, CreateBroadcastRequest, Source, StatusResponse
from .registry import BroadcastRegistry

logging.basicConfig(level=get_settings().log_level.upper())
logger = logging.getLogger("broadcaster")

# Process-wide registry of live broadcasts (the only runtime state we hold).
registry = BroadcastRegistry(get_settings())


@asynccontextmanager
async def lifespan(_app: FastAPI):
    """Ensure every broadcast is torn down when the process stops."""
    yield
    await registry.shutdown()


app = FastAPI(title="Black Candy Store Broadcaster", version="1.0.0", lifespan=lifespan)


@app.get("/healthz")
async def healthz() -> dict[str, str]:
    """Liveness probe."""
    return {"status": "ok"}


@app.post("/broadcasts", response_model=BroadcastHandle)
async def create_broadcast(request: CreateBroadcastRequest) -> BroadcastHandle | JSONResponse:
    """Spin up a continuous broadcast for a station/session id."""
    try:
        await registry.create(request)
    except BroadcastAlreadyExists as exc:
        logger.warning("duplicate broadcast: %s", exc)
        return JSONResponse(status_code=409, content={"error": "broadcast_exists", "message": str(exc)})

    logger.info("broadcast %s started", request.id)
    return BroadcastHandle(id=request.id, listen_path=f"/internal/broadcasts/{request.id}/listen", running=True)


@app.delete("/broadcasts/{broadcast_id}")
async def delete_broadcast(broadcast_id: str) -> JSONResponse:
    """Stop and tear down a broadcast (Req 10.2, 12.1)."""
    try:
        await registry.remove(broadcast_id)
    except BroadcastNotFound as exc:
        logger.warning("delete of missing broadcast: %s", exc)
        return JSONResponse(status_code=404, content={"error": "broadcast_not_found", "message": str(exc)})
    return JSONResponse(status_code=200, content={"status": "stopped", "id": broadcast_id})


@app.post("/broadcasts/{broadcast_id}/next")
async def next_source(broadcast_id: str, source: Source) -> JSONResponse:
    """Provide the next resolved source (song path + token, or continuity).

    The decision of *what* comes next is always Rails' (the Program_Sequencer);
    the broadcaster only encodes and fans out what it is handed (Req 2.2, 2.3).
    """
    try:
        broadcast = registry.get(broadcast_id)
    except BroadcastNotFound as exc:
        return JSONResponse(status_code=404, content={"error": "broadcast_not_found", "message": str(exc)})
    broadcast.enqueue_source(source)
    return JSONResponse(status_code=202, content={"status": "queued", "id": broadcast_id, "kind": source.kind})


@app.get("/broadcasts/{broadcast_id}/status", response_model=StatusResponse)
async def broadcast_status(broadcast_id: str) -> StatusResponse | JSONResponse:
    """Report the current encode position, listener count, and uptime."""
    try:
        broadcast = registry.get(broadcast_id)
    except BroadcastNotFound as exc:
        return JSONResponse(status_code=404, content={"error": "broadcast_not_found", "message": str(exc)})
    return StatusResponse(
        id=broadcast.id,
        running=broadcast.running,
        position_seconds=round(broadcast.position_seconds, 3),
        listener_count=broadcast.listener_count,
        listener_limit=broadcast.listener_limit,
        uptime_seconds=round(broadcast.uptime_seconds, 3),
        current_source_kind=broadcast.current_source_kind,
    )


@app.get("/internal/broadcasts/{broadcast_id}/listen", response_model=None)
async def listen(broadcast_id: str) -> StreamingResponse | JSONResponse:
    """The raw MP3 fan-out: serve the CURRENT position to a new listener.

    Loopback-only (the server binds to loopback); Rails reverse-proxies public
    clients here after doing all authorization. Refuses at the listener limit
    without disturbing existing listeners (Req 11.7); otherwise streams the
    single shared encode from wherever it currently is (Req 2.4, 3.2).
    """
    try:
        broadcast = registry.get(broadcast_id)
    except BroadcastNotFound as exc:
        return JSONResponse(status_code=404, content={"error": "broadcast_not_found", "message": str(exc)})

    try:
        listener = broadcast.add_listener()
    except ListenerLimitReached as exc:
        logger.info("listener refused (capacity): %s", exc)
        return JSONResponse(status_code=503, content={"error": "listener_limit_reached", "message": str(exc)})

    async def body(listener: Listener = listener):
        try:
            async for chunk in listener.stream():
                yield chunk
        finally:
            broadcast.remove_listener(listener)

    return StreamingResponse(body(), media_type="audio/mpeg")


def run() -> None:
    """Entry point for ``python -m broadcaster`` / the container CMD."""
    import uvicorn

    settings = get_settings()
    uvicorn.run(
        "broadcaster.main:app",
        host=settings.broadcaster_host,
        port=settings.broadcaster_port,
        log_level=settings.log_level.lower(),
    )
