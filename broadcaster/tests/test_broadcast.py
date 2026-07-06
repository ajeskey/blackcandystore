"""Unit tests for the continuous encode loop, fan-out, and listener accounting."""

import asyncio

import pytest

from broadcaster.broadcast import Broadcast
from broadcaster.errors import ListenerLimitReached
from broadcaster.models import CONTINUITY, SONG, Source

from .conftest import fake_encoder


async def _drain(listener, n, timeout=1.0):
    """Collect up to ``n`` chunks from a listener."""
    chunks = []
    async for chunk in listener.stream():
        chunks.append(chunk)
        if len(chunks) >= n:
            break
    return chunks


async def test_encode_advances_with_zero_listeners(params):
    """The shared encode advances in real time even with nobody connected (Req 2.1, 2.6)."""
    broadcast = Broadcast("b1", params=params, encoder_factory=fake_encoder)
    await broadcast.start()
    try:
        assert broadcast.listener_count == 0
        await asyncio.sleep(0.05)
        assert broadcast.position_seconds > 0
        assert broadcast.uptime_seconds > 0
    finally:
        await broadcast.stop()


async def test_listener_receives_from_current_position(params):
    """A joining listener is fed the live fan-out, i.e. the current position (Req 2.4, 3.2)."""
    broadcast = Broadcast("b2", params=params, encoder_factory=fake_encoder)
    await broadcast.start()
    try:
        listener = broadcast.add_listener()
        assert broadcast.listener_count == 1
        chunks = await asyncio.wait_for(_drain(listener, 3), timeout=1.0)
        assert len(chunks) == 3
        assert listener.bytes_sent == sum(len(c) for c in chunks)
    finally:
        await broadcast.stop()


async def test_zero_or_more_concurrent_listeners_share_one_position(params):
    """Multiple listeners consume the same shared encode concurrently (Req 2.6)."""
    broadcast = Broadcast("b3", params=params, encoder_factory=fake_encoder)
    await broadcast.start()
    try:
        a = broadcast.add_listener()
        b = broadcast.add_listener()
        assert broadcast.listener_count == 2
        a_chunks, b_chunks = await asyncio.wait_for(
            asyncio.gather(_drain(a, 2), _drain(b, 2)), timeout=1.0
        )
        assert len(a_chunks) == 2
        assert len(b_chunks) == 2
    finally:
        await broadcast.stop()


async def test_listener_limit_refuses_without_disturbing_others(params):
    """At the limit a new listener is refused; existing ones are untouched (Req 11.7)."""
    broadcast = Broadcast("b4", params=params, listener_limit=1, encoder_factory=fake_encoder)
    await broadcast.start()
    try:
        first = broadcast.add_listener()
        with pytest.raises(ListenerLimitReached):
            broadcast.add_listener()
        # The existing listener is still connected and still fed.
        assert broadcast.listener_count == 1
        chunks = await asyncio.wait_for(_drain(first, 1), timeout=1.0)
        assert len(chunks) == 1
    finally:
        await broadcast.stop()


async def test_slow_listener_is_dropped_not_backpressuring(params):
    """A listener that never drains past its buffer is dropped (Req 11.7)."""
    broadcast = Broadcast(
        "b5", params=params, listener_buffer_chunks=4, encoder_factory=fake_encoder
    )
    await broadcast.start()
    try:
        broadcast.add_listener()  # never consumed
        # Give the encode loop time to overflow the tiny buffer and reap it.
        await asyncio.sleep(0.1)
        assert broadcast.listener_count == 0
        # The broadcast itself keeps advancing regardless.
        assert broadcast.position_seconds > 0
    finally:
        await broadcast.stop()


async def test_starts_on_continuity_then_switches_to_song(params):
    """With no source the loop emits continuity; a queued song takes over (Req 2.5)."""
    broadcast = Broadcast("b6", params=params, encoder_factory=fake_encoder)
    await broadcast.start()
    try:
        await asyncio.sleep(0.02)
        assert broadcast.current_source_kind == CONTINUITY
        broadcast.enqueue_source(Source(kind=SONG, source_url="/stream/1", stream_token="t"))
        await asyncio.sleep(0.05)
        assert broadcast.current_source_kind == SONG
    finally:
        await broadcast.stop()


async def test_stop_disconnects_listeners(params):
    """Stopping a broadcast closes out its listeners (teardown, Req 12.1)."""
    broadcast = Broadcast("b7", params=params, encoder_factory=fake_encoder)
    await broadcast.start()
    listener = broadcast.add_listener()
    await broadcast.stop()
    assert broadcast.listener_count == 0
    assert broadcast.running is False
    # A consumer draining the closed listener terminates rather than hanging.
    chunks = await asyncio.wait_for(_drain(listener, 5), timeout=1.0)
    assert isinstance(chunks, list)
