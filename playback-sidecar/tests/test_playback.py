"""Playback dispatch: URL building, device routing, credential/auth handling."""

import pytest

from sidecar.errors import DeviceAuthenticationError, PlaybackFailed
from sidecar.models import AIRPLAY, CHROMECAST, PlayDeviceDescriptor, PlayRequest
from sidecar.playback import build_stream_url, dispatch


def test_build_stream_url_joins_base_path_and_token():
    url = build_stream_url("http://host:3000", "/stream/42", "tok123")
    assert url == "http://host:3000/stream/42?stream_token=tok123"


def test_build_stream_url_appends_token_when_path_has_query():
    url = build_stream_url("http://host:3000/", "/stream/remote/7?x=1", "tok")
    assert url == "http://host:3000/stream/remote/7?x=1&stream_token=tok"


def test_build_stream_url_without_token():
    assert build_stream_url("http://host:3000", "/stream/42", None) == "http://host:3000/stream/42"


async def test_dispatches_to_each_device_with_resolved_url():
    calls = []

    async def player(descriptor, url, credential, *, content_type, timeout):
        calls.append((descriptor.identifier, url, credential))

    request = PlayRequest(
        device_ids=[1, 2],
        devices=[
            PlayDeviceDescriptor(id=1, identifier="air-1", protocol=AIRPLAY),
            PlayDeviceDescriptor(id=2, identifier="cast-1", protocol=CHROMECAST),
        ],
        stream_source="local",
        stream_url="/stream/9",
        stream_token="t",
        credentials={},
    )

    await dispatch(
        request,
        base_url="http://host:3000",
        content_type="audio/mpeg",
        timeout=5,
        players={"airplay": player, "chromecast": player},
    )

    played = {identifier for identifier, _url, _cred in calls}
    assert played == {"air-1", "cast-1"}
    assert all(url == "http://host:3000/stream/9?stream_token=t" for _id, url, _c in calls)


async def test_credentials_are_passed_by_rails_device_id():
    seen = {}

    async def player(descriptor, url, credential, *, content_type, timeout):
        seen[descriptor.identifier] = credential

    request = PlayRequest(
        devices=[PlayDeviceDescriptor(id=7, identifier="air-7", protocol=AIRPLAY, requires_password=True)],
        stream_source="local",
        stream_url="/stream/1",
        credentials={"7": "hunter2"},
    )

    await dispatch(request, base_url="http://h", content_type="audio/mpeg", timeout=5,
                   players={"airplay": player})

    assert seen["air-7"] == "hunter2"


async def test_auth_error_is_surfaced_over_other_failures():
    async def auth_fail(descriptor, url, credential, *, content_type, timeout):
        raise DeviceAuthenticationError("bad pin")

    async def other_fail(descriptor, url, credential, *, content_type, timeout):
        raise PlaybackFailed("boom")

    request = PlayRequest(
        devices=[
            PlayDeviceDescriptor(id=1, identifier="a", protocol=AIRPLAY),
            PlayDeviceDescriptor(id=2, identifier="b", protocol=CHROMECAST),
        ],
        stream_source="local",
        stream_url="/stream/1",
    )

    with pytest.raises(DeviceAuthenticationError):
        await dispatch(request, base_url="http://h", content_type="audio/mpeg", timeout=5,
                       players={"airplay": auth_fail, "chromecast": other_fail})


async def test_unsupported_protocol_fails():
    request = PlayRequest(
        devices=[PlayDeviceDescriptor(id=1, identifier="x", protocol="bogus")],
        stream_source="local",
        stream_url="/stream/1",
    )

    with pytest.raises(PlaybackFailed):
        await dispatch(request, base_url="http://h", content_type="audio/mpeg", timeout=5,
                       players={})
