"""Domain errors mapped onto HTTP responses the Rails client understands."""

from __future__ import annotations


class SidecarError(Exception):
    """Base class for sidecar failures."""


class DeviceNotFound(SidecarError):
    """A requested target device is not currently reachable on the network."""


class DeviceAuthenticationError(SidecarError):
    """A password-protected device rejected (or was missing) its credential.

    Rails maps the resulting 401/403 to ``device_authentication_error``.
    """


class PlaybackFailed(SidecarError):
    """The device was reached but playback could not be started."""
