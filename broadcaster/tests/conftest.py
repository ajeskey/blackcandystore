"""Shared test fixtures.

Every test injects a **fake encoder** in place of ffmpeg, so the encode loop,
fan-out, and listener accounting run without real audio or an ffmpeg install.
"""

import asyncio
from collections.abc import AsyncIterator

import pytest

from broadcaster.config import get_settings
from broadcaster.encoder import EncodeParams
from broadcaster.models import Source


async def fake_encoder(source: Source, params: EncodeParams) -> AsyncIterator[bytes]:
    """Yield fixed-size chunks forever (stands in for a real-time ffmpeg encode).

    Sleeps briefly between chunks so the event loop can interleave listeners and
    the broadcast's stop/cancel, mirroring ffmpeg's real-time (`-re`) pacing.
    """
    while True:
        await asyncio.sleep(0.001)
        yield b"\x00" * params.chunk_size


@pytest.fixture
def params() -> EncodeParams:
    settings = get_settings()
    return EncodeParams(
        bitrate_kbps=settings.bitrate_kbps,
        sample_rate=settings.sample_rate,
        channels=settings.channels,
        chunk_size=settings.chunk_size,
        ffmpeg_binary=settings.ffmpeg_binary,
        base_url=settings.black_candy_url,
    )
