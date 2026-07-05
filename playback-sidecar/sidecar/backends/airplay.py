"""AirPlay discovery and playback via ``pyatv``.

pyatv is asyncio-native, so these coroutines drive it directly. Device password
requirements and credentials are handled through pyatv's pairing model: a
protected device needs stored credentials set on the config before connecting.
"""

from __future__ import annotations

import asyncio
import logging

from ..errors import DeviceAuthenticationError, DeviceNotFound, PlaybackFailed
from ..models import AIRPLAY, Device, PlayDeviceDescriptor

logger = logging.getLogger(__name__)


def _airplay_service(conf):
    import pyatv.const

    return conf.get_service(pyatv.const.Protocol.AirPlay)


async def scan(timeout: float) -> list[Device]:
    """Return the AirPlay devices currently advertised on the network."""
    try:
        import pyatv

        loop = asyncio.get_running_loop()
        confs = await pyatv.scan(loop, timeout=timeout)

        devices: list[Device] = []
        for conf in confs:
            service = _airplay_service(conf)
            if service is None:
                continue
            devices.append(
                Device(
                    identifier=str(conf.identifier),
                    name=conf.name,
                    protocol=AIRPLAY,
                    requires_password=bool(getattr(service, "requires_password", False)),
                )
            )
        return devices
    except Exception:  # noqa: BLE001 - discovery must degrade, never raise
        logger.exception("airplay discovery failed")
        return []


async def _find_conf(identifier: str, timeout: float):
    import pyatv

    loop = asyncio.get_running_loop()
    confs = await pyatv.scan(loop, identifier=identifier, timeout=timeout)
    return confs[0] if confs else None


async def play(
    descriptor: PlayDeviceDescriptor,
    url: str,
    credential: str | None,
    *,
    content_type: str,
    timeout: float,
) -> None:
    """Start streaming ``url`` to the AirPlay device named by ``descriptor``."""
    import pyatv
    import pyatv.const

    conf = await _find_conf(descriptor.identifier, timeout)
    if conf is None:
        raise DeviceNotFound(f"airplay device {descriptor.identifier} is not reachable")

    if descriptor.requires_password and not credential:
        raise DeviceAuthenticationError(
            f"airplay device {descriptor.identifier} requires a credential"
        )
    if credential:
        conf.set_credentials(pyatv.const.Protocol.AirPlay, credential)

    loop = asyncio.get_running_loop()
    try:
        atv = await pyatv.connect(conf, loop)
    except Exception as exc:  # noqa: BLE001 - map connect/auth failures
        message = str(exc).lower()
        if "auth" in message or "credential" in message or "pin" in message:
            raise DeviceAuthenticationError(str(exc)) from exc
        raise PlaybackFailed(str(exc)) from exc

    try:
        await asyncio.wait_for(atv.stream.play_url(url), timeout=timeout)
    except DeviceAuthenticationError:
        raise
    except Exception as exc:  # noqa: BLE001
        logger.exception("airplay playback failed for %s", descriptor.identifier)
        raise PlaybackFailed(str(exc)) from exc
    finally:
        atv.close()
