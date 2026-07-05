"""Dispatch a resolved audio stream to a set of Output_Devices.

Rails hands us the fully-resolved stream path plus a signed token and the target
device descriptors. We build the absolute, authorized fetch URL, then play it on
every target concurrently. More than one device forms a synchronized group as
far as Rails is concerned; each protocol backend drives its own devices.
"""

from __future__ import annotations

import asyncio
import logging
from collections.abc import Awaitable, Callable
from urllib.parse import urlencode, urljoin

from .backends import airplay, chromecast
from .errors import DeviceAuthenticationError, PlaybackFailed
from .models import PlayDeviceDescriptor, PlayRequest

logger = logging.getLogger(__name__)

# A player plays `url` on one device, optionally with a credential.
Player = Callable[..., Awaitable[None]]

DEFAULT_PLAYERS: dict[str, Player] = {
    "airplay": airplay.play,
    "chromecast": chromecast.play,
}


def build_stream_url(base_url: str, stream_url: str, stream_token: str | None) -> str:
    """Join the same-origin ``stream_url`` to the app base and attach the token.

    The token is what lets the sidecar fetch the audio without a login session
    (verified by Rails' SidecarStreamAccess).
    """
    absolute = urljoin(base_url.rstrip("/") + "/", stream_url.lstrip("/"))
    if stream_token:
        separator = "&" if "?" in absolute else "?"
        absolute = f"{absolute}{separator}{urlencode({'stream_token': stream_token})}"
    return absolute


async def dispatch(
    request: PlayRequest,
    *,
    base_url: str,
    content_type: str,
    timeout: float,
    players: dict[str, Player] | None = None,
) -> None:
    """Play the requested stream on every target device.

    Raises DeviceAuthenticationError if any protected device's credential is
    missing/incorrect, or PlaybackFailed if a reachable device cannot start.
    """
    players = players or DEFAULT_PLAYERS
    url = build_stream_url(base_url, request.stream_url, request.stream_token)

    async def play_one(descriptor: PlayDeviceDescriptor) -> None:
        player = players.get(descriptor.protocol)
        if player is None:
            raise PlaybackFailed(f"unsupported protocol: {descriptor.protocol}")
        credential = request.credentials.get(str(descriptor.id))
        await player(
            descriptor,
            url,
            credential,
            content_type=content_type,
            timeout=timeout,
        )

    results = await asyncio.gather(
        *(play_one(descriptor) for descriptor in request.devices),
        return_exceptions=True,
    )

    # Surface an auth failure preferentially (Rails maps it to a 401 -> retry
    # with a credential); otherwise surface the first playback failure.
    auth_error = next((r for r in results if isinstance(r, DeviceAuthenticationError)), None)
    if auth_error is not None:
        raise auth_error
    failure = next((r for r in results if isinstance(r, BaseException)), None)
    if failure is not None:
        raise failure
