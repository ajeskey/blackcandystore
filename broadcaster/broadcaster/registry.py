"""In-memory registry of live broadcasts.

This is the whole of the broadcaster's "state": a map of id -> running
``Broadcast``. It is intentionally **non-authoritative** and non-persistent --
if the process restarts, this map is empty and Rails re-creates the broadcasts
it believes should be running from its own persisted state (Req 10.4). The
registry only knows what is running *here, right now*.
"""

from __future__ import annotations

import logging

from .broadcast import Broadcast, EncoderFactory
from .config import Settings
from .encoder import EncodeParams, ffmpeg_encode
from .errors import BroadcastAlreadyExists, BroadcastNotFound
from .models import CreateBroadcastRequest

logger = logging.getLogger(__name__)


class BroadcastRegistry:
    """Tracks the broadcasts currently running in this process."""

    def __init__(self, settings: Settings, encoder_factory: EncoderFactory = ffmpeg_encode) -> None:
        self._settings = settings
        self._encoder_factory = encoder_factory
        self._broadcasts: dict[str, Broadcast] = {}

    def _params_for(self, bitrate_kbps: int | None) -> EncodeParams:
        return EncodeParams(
            bitrate_kbps=bitrate_kbps or self._settings.bitrate_kbps,
            sample_rate=self._settings.sample_rate,
            channels=self._settings.channels,
            chunk_size=self._settings.chunk_size,
            ffmpeg_binary=self._settings.ffmpeg_binary,
            base_url=self._settings.black_candy_url,
        )

    async def create(self, request: CreateBroadcastRequest) -> Broadcast:
        """Start a new broadcast, refusing a duplicate id."""
        if request.id in self._broadcasts:
            raise BroadcastAlreadyExists(f"broadcast {request.id} already running")
        broadcast = Broadcast(
            request.id,
            params=self._params_for(request.bitrate_kbps),
            listener_limit=request.listener_limit,
            listener_buffer_chunks=self._settings.listener_buffer_chunks,
            encoder_factory=self._encoder_factory,
        )
        self._broadcasts[request.id] = broadcast
        await broadcast.start(request.initial_source)
        logger.info("created broadcast %s (now %d live)", request.id, len(self._broadcasts))
        return broadcast

    def get(self, broadcast_id: str) -> Broadcast:
        """Return a running broadcast or raise ``BroadcastNotFound``."""
        try:
            return self._broadcasts[broadcast_id]
        except KeyError as exc:
            raise BroadcastNotFound(f"broadcast {broadcast_id} is not running") from exc

    async def remove(self, broadcast_id: str) -> None:
        """Stop and forget a broadcast."""
        broadcast = self.get(broadcast_id)
        await broadcast.stop()
        self._broadcasts.pop(broadcast_id, None)
        logger.info("removed broadcast %s (now %d live)", broadcast_id, len(self._broadcasts))

    async def shutdown(self) -> None:
        """Stop every broadcast (process teardown)."""
        for broadcast in list(self._broadcasts.values()):
            await broadcast.stop()
        self._broadcasts.clear()

    def __len__(self) -> int:
        return len(self._broadcasts)
