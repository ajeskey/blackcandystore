"""Runtime configuration, sourced from environment variables.

Defaults assume the broadcaster is co-located with the Rails app (same host/pod)
and never exposed publicly: Rails reaches the broadcaster on **loopback** and
reverse-proxies the internal listen endpoint to public clients, so the
broadcaster binds to loopback by default (unlike the discovery sidecar, which
must bind broadly to reach the LAN). The broadcaster reaches Rails on loopback
``3000`` to fetch resolved source audio.
"""

from __future__ import annotations

from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Broadcaster settings, overridable via environment variables."""

    model_config = SettingsConfigDict(env_prefix="", case_sensitive=False)

    # Where the broadcaster's own HTTP server listens. Loopback-only by design:
    # both the control contract and the /internal listen fan-out are private to
    # the host; Rails is the single authenticated public surface.
    broadcaster_host: str = "127.0.0.1"
    broadcaster_port: int = 9340

    # Base URL of the Black Candy Store app the broadcaster fetches source audio
    # from. A source path handed to `POST /next` is a same-origin path on this
    # host; the broadcaster joins it to this base and appends the signed token.
    black_candy_url: str = "http://127.0.0.1:3000"

    # Constant-bitrate MP3 encode parameters. A fixed bitrate is what makes the
    # single shared encode joinable mid-stream by any generic MP3 client and
    # lets byte offsets map cleanly to a wall-clock position (Req 2.4, 3.1).
    bitrate_kbps: int = 128
    sample_rate: int = 44100
    channels: int = 2

    # ffmpeg executable used for the continuous encode loop.
    ffmpeg_binary: str = "ffmpeg"

    # Bytes read from the encoder per fan-out chunk.
    chunk_size: int = 4096

    # Per-listener buffered chunks. A listener that cannot keep up past this
    # backlog is dropped (Icecast-style) rather than stalling the shared encode.
    listener_buffer_chunks: int = 256

    log_level: str = "INFO"


@lru_cache
def get_settings() -> Settings:
    """Return the process-wide settings singleton."""
    return Settings()
