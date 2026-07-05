"""Protocol-specific discovery and playback backends.

Each backend module exposes two coroutines with a uniform shape:

    async def scan(timeout: float) -> list[Device]
    async def play(descriptor: PlayDeviceDescriptor, url: str,
                   credential: str | None, *, content_type: str,
                   timeout: float) -> None

Heavy protocol libraries (pychromecast, pyatv) are imported lazily inside these
functions so the package imports cleanly in environments without them (e.g.
unit tests that stub the backends).
"""
