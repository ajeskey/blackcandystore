"""Discovery merges protocol backends and degrades gracefully."""

from sidecar.discovery import discover_devices
from sidecar.models import AIRPLAY, CHROMECAST, Device


async def test_merges_devices_from_all_backends():
    async def airplay_scan(_timeout):
        return [Device(identifier="a1", name="Kitchen", protocol=AIRPLAY)]

    async def chromecast_scan(_timeout):
        return [Device(identifier="c1", name="TV", protocol=CHROMECAST)]

    devices = await discover_devices(
        1.0, scanners={"airplay": airplay_scan, "chromecast": chromecast_scan}
    )

    identifiers = {d.identifier for d in devices}
    assert identifiers == {"a1", "c1"}


async def test_deduplicates_by_identifier():
    async def scan_a(_timeout):
        return [Device(identifier="dup", name="One", protocol=AIRPLAY)]

    async def scan_b(_timeout):
        return [Device(identifier="dup", name="Two", protocol=CHROMECAST)]

    devices = await discover_devices(1.0, scanners={"a": scan_a, "b": scan_b})

    assert len(devices) == 1


async def test_a_failing_backend_does_not_fail_the_scan():
    async def good(_timeout):
        return [Device(identifier="ok", protocol=CHROMECAST)]

    async def broken(_timeout):
        raise RuntimeError("mdns exploded")

    devices = await discover_devices(1.0, scanners={"good": good, "broken": broken})

    assert [d.identifier for d in devices] == ["ok"]
