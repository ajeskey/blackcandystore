"""HTTP surface of the playback sidecar (FastAPI).

Implements the three-endpoint contract the Black Candy Store Rails app calls:

    GET  /healthz  -> liveness
    GET  /devices  -> currently advertised Output_Devices
    POST /play     -> stream a resolved audio URL to a set of devices
"""

from __future__ import annotations

import logging

from fastapi import FastAPI
from fastapi.responses import JSONResponse

from .config import get_settings
from .discovery import discover_devices
from .errors import DeviceAuthenticationError, DeviceNotFound, PlaybackFailed
from .models import DevicesResponse, PlayRequest, PlayResponse
from .playback import dispatch

logging.basicConfig(level=get_settings().log_level.upper())
logger = logging.getLogger("sidecar")

app = FastAPI(title="Black Candy Store Playback Sidecar", version="1.0.0")


@app.get("/healthz")
async def healthz() -> dict[str, str]:
    """Liveness probe."""
    return {"status": "ok"}


@app.get("/devices", response_model=DevicesResponse)
async def devices() -> DevicesResponse:
    """Return the Output_Devices currently advertised on the local network.

    Always succeeds with a (possibly empty) list; discovery failures degrade to
    an empty result so the Rails side can reconcile its cache safely.
    """
    settings = get_settings()
    found = await discover_devices(settings.discovery_timeout)
    logger.info("discovered %d device(s)", len(found))
    return DevicesResponse(devices=found)


@app.post("/play", response_model=PlayResponse)
async def play(request: PlayRequest) -> PlayResponse | JSONResponse:
    """Start streaming the resolved audio URL to the requested devices."""
    settings = get_settings()
    try:
        await dispatch(
            request,
            base_url=settings.black_candy_url,
            content_type=settings.play_content_type,
            timeout=settings.play_timeout,
        )
    except DeviceAuthenticationError as exc:
        logger.warning("device authentication failed: %s", exc)
        return JSONResponse(status_code=401, content={"error": "device_authentication_error", "message": str(exc)})
    except DeviceNotFound as exc:
        logger.warning("device not found: %s", exc)
        return JSONResponse(status_code=404, content={"error": "device_not_found", "message": str(exc)})
    except PlaybackFailed as exc:
        logger.error("playback failed: %s", exc)
        return JSONResponse(status_code=502, content={"error": "playback_failed", "message": str(exc)})

    logger.info("playing on device_ids=%s", request.device_ids)
    return PlayResponse(status="playing", device_ids=request.device_ids)


def run() -> None:
    """Entry point for ``python -m sidecar`` / the container CMD."""
    import uvicorn

    settings = get_settings()
    uvicorn.run(
        "sidecar.main:app",
        host=settings.sidecar_host,
        port=settings.sidecar_port,
        log_level=settings.log_level.lower(),
    )
