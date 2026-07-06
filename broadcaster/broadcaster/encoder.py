"""The ffmpeg-based constant-bitrate MP3 encode step.

This module owns *only* the "turn one source into a real-time CBR MP3 byte
stream" concern. The continuous loop, fan-out, and listener accounting live in
``broadcast.py``. Keeping the encoder a small injectable seam (a callable that
yields byte chunks) lets the broadcast machinery be exercised in tests with a
fake generator, exactly how the sidecar makes its protocol backends injectable.
"""

from __future__ import annotations

import asyncio
import logging
from collections.abc import AsyncIterator
from dataclasses import dataclass
from urllib.parse import urlencode, urljoin

from .errors import EncoderError
from .models import CONTINUITY, Source

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class EncodeParams:
    """Constant-bitrate MP3 encode settings shared by every source."""

    bitrate_kbps: int
    sample_rate: int
    channels: int
    chunk_size: int
    ffmpeg_binary: str
    base_url: str

    @property
    def byte_rate(self) -> float:
        """Encoded bytes per second at this constant bitrate.

        This is what maps a byte offset in the shared encode to a wall-clock
        position, so a joining listener can be served "the current position".
        """
        return self.bitrate_kbps * 1000 / 8.0


def build_source_url(base_url: str, source_url: str, stream_token: str | None) -> str:
    """Join a same-origin ``source_url`` to the app base and attach the token.

    Mirrors the sidecar's ``build_stream_url``: the token authorizes the fetch
    without a login session (verified by Rails' stream-access concern).
    """
    absolute = urljoin(base_url.rstrip("/") + "/", source_url.lstrip("/"))
    if stream_token:
        separator = "&" if "?" in absolute else "?"
        absolute = f"{absolute}{separator}{urlencode({'stream_token': stream_token})}"
    return absolute


def build_ffmpeg_command(source: Source, params: EncodeParams) -> list[str]:
    """Build the ffmpeg argv for encoding ``source`` to a real-time CBR MP3.

    ``-re`` reads the input at its native (real-time) rate so the shared encode
    advances in wall-clock time -- the property that makes it a continuous,
    listener-independent broadcast (Req 2.1, 2.6). Continuity emits silence via
    the ``anullsrc`` virtual input so the stream stays open with no eligible
    song (Req 2.5).
    """
    common_output = [
        "-vn",
        "-acodec", "libmp3lame",
        "-b:a", f"{params.bitrate_kbps}k",
        "-ar", str(params.sample_rate),
        "-ac", str(params.channels),
        "-f", "mp3",
        "pipe:1",
    ]

    if source.kind == CONTINUITY or not source.source_url:
        return [
            params.ffmpeg_binary,
            "-hide_banner",
            "-loglevel", "error",
            "-re",
            "-f", "lavfi",
            "-i", f"anullsrc=r={params.sample_rate}:cl=stereo",
            *common_output,
        ]

    url = build_source_url(params.base_url, source.source_url, source.stream_token)
    return [
        params.ffmpeg_binary,
        "-hide_banner",
        "-loglevel", "error",
        "-re",
        "-i", url,
        *common_output,
    ]


async def ffmpeg_encode(source: Source, params: EncodeParams) -> AsyncIterator[bytes]:
    """Spawn ffmpeg for ``source`` and yield CBR MP3 chunks as they are produced.

    The generator ends naturally when the source finishes (ffmpeg exits); for a
    continuity source ffmpeg runs until the generator is closed by the caller
    (i.e. when an eligible song arrives, or the broadcast stops).
    """
    command = build_ffmpeg_command(source, params)
    logger.debug("starting encoder: %s", " ".join(command))
    try:
        process = await asyncio.create_subprocess_exec(
            *command,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
    except FileNotFoundError as exc:  # ffmpeg not installed
        raise EncoderError(f"ffmpeg not found: {params.ffmpeg_binary}") from exc

    assert process.stdout is not None
    try:
        while True:
            chunk = await process.stdout.read(params.chunk_size)
            if not chunk:
                break
            yield chunk
    finally:
        if process.returncode is None:
            process.terminate()
            try:
                await asyncio.wait_for(process.wait(), timeout=5.0)
            except asyncio.TimeoutError:
                process.kill()
                await process.wait()
