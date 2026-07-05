"""HTTP contract tests using FastAPI's TestClient with backends stubbed."""

import pytest
from fastapi.testclient import TestClient

from sidecar import main
from sidecar.errors import DeviceAuthenticationError, PlaybackFailed
from sidecar.models import AIRPLAY, Device


@pytest.fixture
def client():
    return TestClient(main.app)


def test_healthz(client):
    response = client.get("/healthz")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_devices_returns_discovered_list(client, monkeypatch):
    async def fake_discover(_timeout):
        return [Device(identifier="a1", name="Kitchen", protocol=AIRPLAY, requires_password=True)]

    monkeypatch.setattr(main, "discover_devices", fake_discover)

    response = client.get("/devices")

    assert response.status_code == 200
    body = response.json()
    assert body["devices"][0]["identifier"] == "a1"
    assert body["devices"][0]["protocol"] == "airplay"
    assert body["devices"][0]["requires_password"] is True


def test_devices_degrades_to_empty_on_no_devices(client, monkeypatch):
    async def fake_discover(_timeout):
        return []

    monkeypatch.setattr(main, "discover_devices", fake_discover)

    response = client.get("/devices")
    assert response.status_code == 200
    assert response.json() == {"devices": []}


def test_play_acknowledges_success(client, monkeypatch):
    async def fake_dispatch(request, **_kwargs):
        return None

    monkeypatch.setattr(main, "dispatch", fake_dispatch)

    response = client.post(
        "/play",
        json={
            "device_ids": [3],
            "devices": [{"id": 3, "identifier": "cast-3", "protocol": "chromecast"}],
            "stream_source": "local",
            "stream_url": "/stream/9",
            "stream_token": "tok",
            "credentials": {},
        },
    )

    assert response.status_code == 200
    assert response.json()["status"] == "playing"
    assert response.json()["device_ids"] == [3]


def test_play_maps_auth_error_to_401(client, monkeypatch):
    async def fake_dispatch(request, **_kwargs):
        raise DeviceAuthenticationError("bad pin")

    monkeypatch.setattr(main, "dispatch", fake_dispatch)

    response = client.post(
        "/play",
        json={
            "devices": [{"id": 1, "identifier": "a", "protocol": "airplay", "requires_password": True}],
            "stream_source": "local",
            "stream_url": "/stream/1",
        },
    )

    assert response.status_code == 401
    assert response.json()["error"] == "device_authentication_error"


def test_play_maps_playback_failure_to_502(client, monkeypatch):
    async def fake_dispatch(request, **_kwargs):
        raise PlaybackFailed("boom")

    monkeypatch.setattr(main, "dispatch", fake_dispatch)

    response = client.post(
        "/play",
        json={
            "devices": [{"id": 1, "identifier": "a", "protocol": "chromecast"}],
            "stream_source": "local",
            "stream_url": "/stream/1",
        },
    )

    assert response.status_code == 502
    assert response.json()["error"] == "playback_failed"
