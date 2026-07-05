"""Chromecast discovery and playback via ``pychromecast``.

pychromecast is a blocking/threaded library, so its calls are dispatched to a
worker thread to avoid blocking the event loop.
"""

from __future__ import annotations

import asyncio
import logging

from ..errors import DeviceNotFound, PlaybackFailed
from ..models import CHROMECAST, Device, PlayDeviceDescriptor

logger = logging.getLogger(__name__)


def _scan_blocking(timeout: float) -> list[Device]:
    import pychromecast

    casts, browser = pychromecast.get_chromecasts(timeout=timeout)
    try:
        devices: list[Device] = []
        for cast in casts:
            info = cast.cast_info
            devices.append(
                Device(
                    identifier=str(info.uuid),
                    name=info.friendly_name,
                    protocol=CHROMECAST,
                    requires_password=False,
                )
            )
        return devices
    finally:
        browser.stop_discovery()


async def scan(timeout: float) -> list[Device]:
    """Return the Chromecast devices currently advertised on the network."""
    try:
        return await asyncio.to_thread(_scan_blocking, timeout)
    except Exception:  # noqa: BLE001 - discovery must degrade, never raise
        logger.exception("chromecast discovery failed")
        return []


def _play_blocking(uuid: str, url: str, content_type: str, timeout: float) -> None:
    import pychromecast

    services, browser = pychromecast.get_listed_chromecasts(uuids=[uuid], timeout=timeout)
    try:
        if not services:
            raise DeviceNotFound(f"chromecast {uuid} is not reachable")

        cast = services[0]
        cast.wait(timeout=timeout)

        controller = cast.media_controller
        controller.play_media(url, content_type)
        controller.block_until_active(timeout=timeout)
        controller.play()
    finally:
        browser.stop_discovery()


async def play(
    descriptor: PlayDeviceDescriptor,
    url: str,
    credential: str | None,
    *,
    content_type: str,
    timeout: float,
) -> None:
    """Start streaming ``url`` to the Chromecast named by ``descriptor``."""
    try:
        await asyncio.to_thread(_play_blocking, descriptor.identifier, url, content_type, timeout)
    except DeviceNotFound:
        raise
    except Exception as exc:  # noqa: BLE001
        logger.exception("chromecast playback failed for %s", descriptor.identifier)
        raise PlaybackFailed(str(exc)) from exc
