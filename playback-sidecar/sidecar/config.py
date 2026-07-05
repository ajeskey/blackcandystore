"""Runtime configuration, sourced from environment variables.

Defaults assume the sidecar is co-located with the Rails app (same host/pod),
so a zero-config deployment works: Rails reaches the sidecar on loopback
``9330`` and the sidecar reaches Rails on loopback ``3000``.
"""

from __future__ import annotations

from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Sidecar settings, overridable via environment variables."""

    model_config = SettingsConfigDict(env_prefix="", case_sensitive=False)

    # Where the sidecar's own HTTP server listens.
    sidecar_host: str = "0.0.0.0"
    sidecar_port: int = 9330

    # Base URL of the Black Candy Store app the sidecar fetches audio from. The
    # `stream_url` in a /play request is a same-origin path on this host; the
    # sidecar joins it to this base and appends the signed `stream_token`.
    black_candy_url: str = "http://127.0.0.1:3000"

    # How long (seconds) to scan the network for advertised devices.
    discovery_timeout: float = 5.0

    # How long (seconds) to wait when connecting to / commanding a device.
    play_timeout: float = 15.0

    # Content type advertised to Chromecast receivers. Black Candy Store streams
    # are audio; transcoded output is MP3. Chromecast needs an explicit type.
    play_content_type: str = "audio/mpeg"

    log_level: str = "INFO"


@lru_cache
def get_settings() -> Settings:
    """Return the process-wide settings singleton."""
    return Settings()
