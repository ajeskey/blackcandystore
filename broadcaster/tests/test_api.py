"""HTTP contract tests using FastAPI's TestClient with the encoder stubbed."""

import pytest
from fastapi.testclient import TestClient

from broadcaster import main
from broadcaster.config import get_settings
from broadcaster.registry import BroadcastRegistry

from .conftest import fake_encoder


@pytest.fixture
def client(monkeypatch):
    # Swap the process registry for one backed by the fake encoder so no real
    # ffmpeg is spawned; the lifespan shutdown reads this same global.
    monkeypatch.setattr(main, "registry", BroadcastRegistry(get_settings(), fake_encoder))
    with TestClient(main.app) as test_client:
        yield test_client


def test_healthz(client):
    response = client.get("/healthz")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_create_returns_handle(client):
    response = client.post("/broadcasts", json={"id": "s1", "listener_limit": 10})
    assert response.status_code == 200
    body = response.json()
    assert body["id"] == "s1"
    assert body["listen_path"] == "/internal/broadcasts/s1/listen"
    assert body["running"] is True


def test_create_duplicate_returns_409(client):
    assert client.post("/broadcasts", json={"id": "s2"}).status_code == 200
    dup = client.post("/broadcasts", json={"id": "s2"})
    assert dup.status_code == 409
    assert dup.json()["error"] == "broadcast_exists"


def test_status_reports_runtime_state(client):
    client.post("/broadcasts", json={"id": "s3", "listener_limit": 5})
    response = client.get("/broadcasts/s3/status")
    assert response.status_code == 200
    body = response.json()
    assert body["id"] == "s3"
    assert body["running"] is True
    assert body["listener_count"] == 0
    assert body["listener_limit"] == 5
    assert body["position_seconds"] >= 0


def test_status_missing_returns_404(client):
    response = client.get("/broadcasts/nope/status")
    assert response.status_code == 404
    assert response.json()["error"] == "broadcast_not_found"


def test_next_queues_source(client):
    client.post("/broadcasts", json={"id": "s4"})
    response = client.post(
        "/broadcasts/s4/next",
        json={"kind": "song", "source_url": "/stream/1", "stream_token": "tok"},
    )
    assert response.status_code == 202
    assert response.json() == {"status": "queued", "id": "s4", "kind": "song"}


def test_next_missing_returns_404(client):
    response = client.post("/broadcasts/nope/next", json={"kind": "continuity"})
    assert response.status_code == 404
    assert response.json()["error"] == "broadcast_not_found"


def test_delete_stops_broadcast(client):
    client.post("/broadcasts", json={"id": "s5"})
    response = client.request("DELETE", "/broadcasts/s5")
    assert response.status_code == 200
    assert response.json() == {"status": "stopped", "id": "s5"}
    # It is gone afterwards.
    assert client.get("/broadcasts/s5/status").status_code == 404


def test_delete_missing_returns_404(client):
    response = client.request("DELETE", "/broadcasts/nope")
    assert response.status_code == 404
    assert response.json()["error"] == "broadcast_not_found"


def test_listen_missing_returns_404(client):
    response = client.get("/internal/broadcasts/nope/listen")
    assert response.status_code == 404
    assert response.json()["error"] == "broadcast_not_found"


def test_listen_at_capacity_returns_503(client):
    # A zero-limit broadcast refuses every listener without disturbing others.
    client.post("/broadcasts", json={"id": "s6", "listener_limit": 0})
    response = client.get("/internal/broadcasts/s6/listen")
    assert response.status_code == 503
    assert response.json()["error"] == "listener_limit_reached"
