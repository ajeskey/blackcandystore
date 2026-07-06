"""Request/response models for the Rails <-> broadcaster control contract.

The field names mirror exactly what the Rails-side control client (task 9.2)
sends and parses, so the two services stay in lock-step -- the same discipline
the playback sidecar's ``models.py`` follows.
"""

from __future__ import annotations

from pydantic import BaseModel, Field

# A resolved source is either a real audio file/stream to encode, or a request
# to emit Continuity_Audio (silence) until an eligible song is handed in.
SONG = "song"
CONTINUITY = "continuity"
SOURCE_KINDS = (SONG, CONTINUITY)


class Source(BaseModel):
    """One resolved source for the encode loop.

    Rails resolves *what* plays (via the Program_Sequencer) and hands the
    broadcaster a same-origin path plus a signed token to fetch it -- the
    broadcaster never decides program content itself.
    """

    # "song" or "continuity". For "continuity" the url/token are ignored.
    kind: str = SONG
    # Same-origin path on the Black Candy Store host to fetch the audio from.
    source_url: str | None = None
    # Short-lived, purpose-scoped signed token authorizing the source fetch.
    stream_token: str | None = None


class CreateBroadcastRequest(BaseModel):
    """Body of ``POST /broadcasts``."""

    # The Rails Radio_Station or Co_Listen_Session id this broadcast serves.
    # Opaque to the broadcaster; used only as the runtime handle key.
    id: str
    # Optional max concurrent listeners; None means unlimited here (Rails still
    # enforces its own admission limit at the reverse-proxy edge, Req 11.7).
    listener_limit: int | None = None
    # Optional CBR override; falls back to the configured default bitrate.
    bitrate_kbps: int | None = None
    # Optional first source so the encode can begin immediately; when omitted
    # the broadcast starts on Continuity_Audio until Rails posts /next.
    initial_source: Source | None = None


class BroadcastHandle(BaseModel):
    """Response envelope for ``POST /broadcasts`` -- the internal stream handle."""

    id: str
    # Loopback path Rails reverse-proxies public listeners to (Req 3.2, 3.3).
    listen_path: str
    running: bool = True


class StatusResponse(BaseModel):
    """Response envelope for ``GET /broadcasts/{id}/status``."""

    id: str
    running: bool
    # Wall-clock position of the continuous encode, derived from encoded bytes
    # at the constant bitrate. Advances whether or not anyone is listening.
    position_seconds: float
    # Current number of connected listeners (byte-layer accounting, Req 11.7).
    listener_count: int
    listener_limit: int | None = None
    # Seconds since the broadcast started encoding.
    uptime_seconds: float
    # "song" or "continuity" -- what the loop is currently emitting.
    current_source_kind: str
