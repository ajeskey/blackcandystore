"""A single continuous broadcast: encode loop + listener fan-out + accounting.

One ``Broadcast`` owns:

* a **continuous encode loop** that pulls sources (songs handed in by Rails via
  ``/next``, or Continuity_Audio when none is queued) and encodes them to a
  single constant-bitrate MP3 byte stream that advances in real time regardless
  of whether anyone is listening (Req 2.1, 2.2, 2.3, 2.5, 2.6);
* **fan-out** to zero-or-more concurrent listeners, each of whom joins at the
  *current* encode position, Icecast/SHOUTcast-style (Req 2.4, 3.2, 7.4);
* **byte-layer listener accounting** and an optional listener limit (Req 11.7).

It deliberately holds no domain state beyond this runtime handle: the "what
plays next" decision always originates in Rails.
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
import time
from collections.abc import AsyncIterator, Callable
from typing import Optional

from .encoder import EncodeParams, ffmpeg_encode
from .errors import ListenerLimitReached
from .models import CONTINUITY, SONG, Source

logger = logging.getLogger(__name__)

# An encoder factory turns a source into an async iterator of MP3 byte chunks.
# ``ffmpeg_encode`` is the production implementation; tests inject a fake.
EncoderFactory = Callable[[Source, EncodeParams], AsyncIterator[bytes]]


class Listener:
    """One connected client's slice of the shared encode.

    A listener is a bounded queue fed from the current encode position. If it
    falls too far behind (a slow or stalled client) it is dropped rather than
    back-pressuring the shared encode -- one listener can never disturb the
    others or the broadcast itself (Req 11.7, 2.6).
    """

    def __init__(self, buffer_chunks: int) -> None:
        self._queue: asyncio.Queue[Optional[bytes]] = asyncio.Queue(maxsize=buffer_chunks)
        self.dropped = False
        self.bytes_sent = 0

    def feed(self, chunk: bytes) -> None:
        """Enqueue a chunk for this listener, marking it dropped if it lags."""
        try:
            self._queue.put_nowait(chunk)
        except asyncio.QueueFull:
            self.dropped = True

    def close(self) -> None:
        """Signal end-of-stream to the listener's consumer."""
        with contextlib.suppress(asyncio.QueueFull):
            self._queue.put_nowait(None)

    async def stream(self) -> AsyncIterator[bytes]:
        """Yield chunks from the current position until closed or dropped."""
        while True:
            chunk = await self._queue.get()
            if chunk is None or self.dropped:
                return
            self.bytes_sent += len(chunk)
            yield chunk


class Broadcast:
    """A live, continuously-encoding broadcast with listener fan-out."""

    def __init__(
        self,
        broadcast_id: str,
        *,
        params: EncodeParams,
        listener_limit: int | None = None,
        listener_buffer_chunks: int = 256,
        encoder_factory: EncoderFactory = ffmpeg_encode,
    ) -> None:
        self.id = broadcast_id
        self._params = params
        self._listener_limit = listener_limit
        self._listener_buffer_chunks = listener_buffer_chunks
        self._encoder_factory = encoder_factory

        self._listeners: set[Listener] = set()
        self._source_queue: asyncio.Queue[Source] = asyncio.Queue()
        self._loop_task: asyncio.Task[None] | None = None
        self._running = False

        self._position_bytes = 0
        self._started_at = 0.0
        self._current_source_kind = CONTINUITY

    # -- lifecycle -----------------------------------------------------------

    async def start(self, initial_source: Source | None = None) -> None:
        """Begin the continuous encode loop (idempotent)."""
        if self._running:
            return
        if initial_source is not None:
            self._source_queue.put_nowait(initial_source)
        self._running = True
        self._started_at = time.monotonic()
        self._loop_task = asyncio.create_task(self._run(), name=f"broadcast:{self.id}")

    async def stop(self) -> None:
        """Stop the encode loop and disconnect every listener."""
        self._running = False
        if self._loop_task is not None:
            self._loop_task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await self._loop_task
            self._loop_task = None
        for listener in list(self._listeners):
            listener.close()
        self._listeners.clear()

    # -- control -------------------------------------------------------------

    def enqueue_source(self, source: Source) -> None:
        """Hand the loop the next resolved source (driven by Rails /next)."""
        self._source_queue.put_nowait(source)

    # -- listeners -----------------------------------------------------------

    def add_listener(self) -> Listener:
        """Admit a new listener at the current position, or refuse at capacity.

        Raises ``ListenerLimitReached`` without disturbing existing listeners
        when the configured limit is already met (Req 11.7).
        """
        if self._listener_limit is not None and len(self._listeners) >= self._listener_limit:
            raise ListenerLimitReached(
                f"broadcast {self.id} at listener limit ({self._listener_limit})"
            )
        listener = Listener(self._listener_buffer_chunks)
        self._listeners.add(listener)
        logger.info("listener joined broadcast %s (now %d)", self.id, len(self._listeners))
        return listener

    def remove_listener(self, listener: Listener) -> None:
        """Detach a listener (on disconnect)."""
        self._listeners.discard(listener)
        logger.info("listener left broadcast %s (now %d)", self.id, len(self._listeners))

    # -- introspection -------------------------------------------------------

    @property
    def running(self) -> bool:
        return self._running

    @property
    def listener_count(self) -> int:
        return len(self._listeners)

    @property
    def listener_limit(self) -> int | None:
        return self._listener_limit

    @property
    def position_seconds(self) -> float:
        """Wall-clock position derived from encoded bytes at the CBR rate."""
        return self._position_bytes / self._params.byte_rate if self._params.byte_rate else 0.0

    @property
    def uptime_seconds(self) -> float:
        return time.monotonic() - self._started_at if self._started_at else 0.0

    @property
    def current_source_kind(self) -> str:
        return self._current_source_kind

    # -- internals -----------------------------------------------------------

    def _fan_out(self, chunk: bytes) -> None:
        """Advance the shared position and push a chunk to every listener."""
        self._position_bytes += len(chunk)
        # Reap listeners the fan-out dropped for lagging.
        for listener in list(self._listeners):
            if listener.dropped:
                self.remove_listener(listener)
                listener.close()
                continue
            listener.feed(chunk)

    def _next_source(self) -> Source:
        """Take the next queued source, or Continuity_Audio when idle (Req 2.5)."""
        try:
            return self._source_queue.get_nowait()
        except asyncio.QueueEmpty:
            return Source(kind=CONTINUITY)

    async def _run(self) -> None:
        """The continuous encode loop -- the heart of the always-on broadcast."""
        while self._running:
            source = self._next_source()
            self._current_source_kind = source.kind if source.kind == SONG else CONTINUITY
            try:
                async for chunk in self._encoder_factory(source, self._params):
                    if not self._running:
                        break
                    self._fan_out(chunk)
                    # While emitting continuity, yield to a real song the moment
                    # Rails queues one rather than finishing an endless silence.
                    if self._current_source_kind == CONTINUITY and not self._source_queue.empty():
                        break
            except Exception:  # noqa: BLE001 - keep the broadcast alive
                logger.exception("encode step failed for broadcast %s; continuing", self.id)
                # Avoid a tight failure spin (e.g. ffmpeg missing in dev).
                await asyncio.sleep(0.5)
