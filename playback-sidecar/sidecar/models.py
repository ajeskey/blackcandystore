"""Request/response models matching the Rails <-> sidecar contract.

The field names mirror exactly what ``DeviceDiscovery`` and ``PlaybackSidecar``
on the Rails side send and parse, so the two services stay in lock-step.
"""

from __future__ import annotations

from pydantic import BaseModel, Field

AIRPLAY = "airplay"
CHROMECAST = "chromecast"
PROTOCOLS = (AIRPLAY, CHROMECAST)


class Device(BaseModel):
    """A discovered Output_Device, as returned by ``GET /devices``."""

    identifier: str
    name: str | None = None
    protocol: str
    requires_password: bool = False


class DevicesResponse(BaseModel):
    """Envelope for the device list (``{"devices": [...]}``)."""

    devices: list[Device] = Field(default_factory=list)


class PlayDeviceDescriptor(BaseModel):
    """One target device in a /play request.

    ``id`` is the Rails Output_Device id (used to key ``credentials``);
    ``identifier`` is the protocol-level id the sidecar uses to reach the real
    device. Rails DB ids are meaningless off that server, so playback keys on
    ``identifier`` + ``protocol``.
    """

    id: int
    identifier: str
    protocol: str
    requires_password: bool = False


class PlayRequest(BaseModel):
    """Body of ``POST /play``."""

    # Rails Output_Device ids; retained for backward compatibility / logging.
    device_ids: list[int] = Field(default_factory=list)
    # Rich descriptors the sidecar actually acts on.
    devices: list[PlayDeviceDescriptor] = Field(default_factory=list)
    # "local" or "remote" — which Rails decoding path produced the stream.
    stream_source: str
    # Same-origin path on the Black Candy Store host to fetch the audio from.
    stream_url: str
    # Short-lived, song-scoped signed token authorizing the stream fetch.
    stream_token: str | None = None
    # Per-device passwords keyed by the Rails Output_Device id (as a string).
    credentials: dict[str, str] = Field(default_factory=dict)


class PlayResponse(BaseModel):
    """Acknowledgement returned by a successful ``POST /play``."""

    status: str = "playing"
    device_ids: list[int] = Field(default_factory=list)
