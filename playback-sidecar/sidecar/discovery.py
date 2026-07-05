"""Cross-protocol device discovery.

Scans every registered protocol backend concurrently and merges the results
into a single device list. Discovery is best-effort: a backend that fails or
finds nothing contributes an empty list rather than failing the whole scan,
mirroring the graceful-degradation contract the Rails side relies on.
"""

from __future__ import annotations

import asyncio
import logging
from collections.abc import Awaitable, Callable

from .backends import airplay, chromecast
from .models import Device

logger = logging.getLogger(__name__)

# A scanner takes a timeout and returns the devices it found.
Scanner = Callable[[float], Awaitable[list[Device]]]

# Default backends, keyed by protocol. Overridable in tests.
DEFAULT_SCANNERS: dict[str, Scanner] = {
    "airplay": airplay.scan,
    "chromecast": chromecast.scan,
}


async def discover_devices(
    timeout: float,
    scanners: dict[str, Scanner] | None = None,
) -> list[Device]:
    """Return the union of devices advertised across all protocol backends."""
    scanners = scanners or DEFAULT_SCANNERS
    results = await asyncio.gather(
        *(scan(timeout) for scan in scanners.values()),
        return_exceptions=True,
    )

    devices: list[Device] = []
    seen: set[str] = set()
    for result in results:
        if isinstance(result, BaseException):
            logger.warning("a discovery backend failed: %s", result)
            continue
        for device in result:
            if device.identifier in seen:
                continue
            seen.add(device.identifier)
            devices.append(device)
    return devices
