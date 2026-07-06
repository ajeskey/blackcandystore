"""Domain errors mapped onto HTTP responses the Rails client understands."""

from __future__ import annotations


class BroadcasterError(Exception):
    """Base class for broadcaster failures."""


class BroadcastNotFound(BroadcasterError):
    """No live broadcast exists for the requested id.

    Because the broadcaster holds no authoritative state, this simply means the
    id is not currently running here; Rails re-establishes it if its own state
    says it should exist.
    """


class BroadcastAlreadyExists(BroadcasterError):
    """A broadcast with the requested id is already running."""


class ListenerLimitReached(BroadcasterError):
    """A new listener was refused because the broadcast is at capacity.

    Rails maps this to a capacity response (Req 11.7) and does not disrupt the
    existing listeners.
    """


class EncoderError(BroadcasterError):
    """The ffmpeg encode loop could not be started or died unexpectedly."""
