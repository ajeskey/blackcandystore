"""Broadcaster integration / smoke tests (task 9.5).

These drive the broadcaster end-to-end through its HTTP surface (and, for the
"restart resume" case, its registry) with the real ffmpeg encoder replaced by
an injected fake, covering the representative flows the requirements call out:

* the shared encode advances with ZERO listeners connected, observed through
  the public ``/status`` contract (Req 2.1, 2.6);
* a single listener, then multiple concurrent listeners, are each served an
  ``audio/mpeg`` stream from the CURRENT position rather than the start of a
  song (Req 2.4, 3.1, 3.2, 3.3, 7.2, 7.4, 7.5, 7.6);
* after a broadcaster "restart" — its non-authoritative in-memory registry is
  lost — a fresh registry re-establishes the broadcast from a re-issued
  ``POST /broadcasts`` and it serves audio again (Req 10.4-style resume; the
  broadcaster holds no state, so Rails re-establishing the broadcast is the
  whole of "resume" on this side).

The encoder is faked (see ``conftest.fake_encoder``) so no real ffmpeg process
or audio is required; the fan-out, listener accounting, position tracking, and
HTTP contract are all exercised for real.
"""

import asyncio
import time

import pytest
from fastapi.testclient import TestClient

from broadcaster import main
from broadcaster.config import get_settings
from broadcaster.errors import BroadcastNotFound
from broadcaster.models import CreateBroadcastRequest
from broadcaster.registry import BroadcastRegistry

from .conftest import fake_encoder


@pytest.fixture
def client(monkeypatch):
    # Swap the process registry for one backed by the fake encoder so no real
    # ffmpeg is spawned; the lifespan shutdown tears down this same global.
    monkeypatch.setattr(main, "registry", BroadcastRegistry(get_settings(), fake_encoder))
    with TestClient(main.app) as test_client:
        yield test_client


async def _drain(body_iterator, n: int = 2) -> list[bytes]:
    """Pull up to ``n`` chunks off a live listen response body, then stop.

    The fan-out is an infinite live stream, so we read a bounded number of
    chunks and close the iterator (which reaps the listener in the handler's
    ``finally``). This drives the real ``StreamingResponse`` body the HTTP
    handler returns, so the bytes served over ``audio/mpeg`` are exercised for
    real without a buffering test transport trying to consume an endless body.
    """
    chunks: list[bytes] = []
    try:
        async for chunk in body_iterator:
            chunks.append(chunk)
            if len(chunks) >= n:
                break
    finally:
        await body_iterator.aclose()
    return chunks


def test_zero_listener_encode_advances_over_http(client):
    """With nobody listening, the encode position keeps advancing (Req 2.1, 2.6)."""
    assert client.post("/broadcasts", json={"id": "z1"}).status_code == 200

    first = client.get("/broadcasts/z1/status").json()
    assert first["running"] is True
    assert first["listener_count"] == 0

    time.sleep(0.1)

    second = client.get("/broadcasts/z1/status").json()
    # Still zero listeners, yet the shared encode moved forward on its own.
    assert second["listener_count"] == 0
    assert second["position_seconds"] > first["position_seconds"]
    assert second["uptime_seconds"] >= first["uptime_seconds"]


async def test_single_listener_served_audio_mpeg_from_current_position(monkeypatch):
    """One listener joins a running stream and is served audio/mpeg (Req 2.4, 3.1, 3.2).

    Drives the real ``listen`` HTTP handler (its ``audio/mpeg`` StreamingResponse
    and listener admission) against a fake-encoder registry. The encode is
    allowed to advance BEFORE the listener joins, so the listener demonstrably
    attaches at the CURRENT position rather than the start of a song.
    """
    registry = BroadcastRegistry(get_settings(), fake_encoder)
    monkeypatch.setattr(main, "registry", registry)
    await registry.create(CreateBroadcastRequest(id="l1"))
    try:
        await asyncio.sleep(0.05)
        assert registry.get("l1").position_seconds > 0  # advanced with zero listeners

        response = await main.listen("l1")
        assert response.status_code == 200
        assert response.media_type == "audio/mpeg"
        assert registry.get("l1").listener_count == 1

        chunks = await _drain(response.body_iterator)
        assert chunks, "the listener should receive live audio bytes"
    finally:
        await registry.shutdown()


async def test_multiple_listeners_each_served_audio_mpeg_from_current_position(monkeypatch):
    """Several concurrent listeners each get audio/mpeg off the one shared encode.

    Every participant tunes into the same continuous stream on their own
    connection from the current position (Req 2.6, 3.3, 7.2, 7.4, 7.5, 7.6).
    """
    registry = BroadcastRegistry(get_settings(), fake_encoder)
    monkeypatch.setattr(main, "registry", registry)
    await registry.create(CreateBroadcastRequest(id="m1"))
    try:
        await asyncio.sleep(0.05)
        assert registry.get("m1").position_seconds > 0

        responses = [await main.listen("m1") for _ in range(3)]
        for response in responses:
            assert response.status_code == 200
            assert response.media_type == "audio/mpeg"

        # All three are accounted for as concurrent listeners on one broadcast.
        assert registry.get("m1").listener_count == 3

        payloads = await asyncio.gather(*(_drain(r.body_iterator) for r in responses))
        assert all(payloads), "every concurrent listener should receive live audio bytes"
    finally:
        await registry.shutdown()


def test_not_running_broadcast_serves_no_audio(client):
    """A listen request for an unknown/not-running broadcast yields no audio (Req 3.6-adjacent)."""
    response = client.get("/internal/broadcasts/never-started/listen")
    assert response.status_code == 404
    assert response.json()["error"] == "broadcast_not_found"


async def test_restart_resume_reestablishes_broadcast_and_serves_again():
    """After a broadcaster restart, a re-issued create re-establishes the stream.

    The broadcaster holds no authoritative state: on restart its registry is
    empty and Rails (the source of truth) re-establishes each broadcast it
    believes should be running. This verifies that once the registry is
    lost/recreated, ``POST /broadcasts`` (modeled here as ``registry.create``)
    brings the broadcast back and it serves audio again (Req 10.4, 2.1, 3.2).
    """
    settings = get_settings()

    # --- before restart: a broadcast is running and serving a listener --------
    registry = BroadcastRegistry(settings, fake_encoder)
    await registry.create(CreateBroadcastRequest(id="colisten:7"))
    broadcast = registry.get("colisten:7")
    listener = broadcast.add_listener()
    chunks = []
    async for chunk in listener.stream():
        chunks.append(chunk)
        if len(chunks) >= 2:
            break
    assert chunks, "the pre-restart broadcast should serve audio"

    # --- restart: the in-memory registry is lost (no persisted state) ---------
    await registry.shutdown()
    assert len(registry) == 0
    with pytest.raises(BroadcastNotFound):
        registry.get("colisten:7")

    # --- resume: a fresh registry re-establishes the same broadcast id --------
    resumed = BroadcastRegistry(settings, fake_encoder)
    await resumed.create(CreateBroadcastRequest(id="colisten:7"))
    resumed_broadcast = resumed.get("colisten:7")
    resumed_listener = resumed_broadcast.add_listener()
    resumed_chunks = []
    async for chunk in resumed_listener.stream():
        resumed_chunks.append(chunk)
        if len(resumed_chunks) >= 2:
            break
    assert resumed_chunks, "the re-established broadcast should serve audio again"

    await resumed.shutdown()
