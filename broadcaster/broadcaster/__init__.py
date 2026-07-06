"""Black Candy Store broadcaster.

An out-of-process **continuous stream assembly + fan-out** server, a sibling of
the playback sidecar. Where the sidecar owns the AirPlay/Chromecast wire
protocols, this service owns the always-on radio/co-listen data plane: for each
active broadcast it runs a continuous, constant-bitrate MP3 encode loop that
advances in real time whether or not anyone is listening, and it fans that
single encode position out to zero-or-more concurrent Icecast/SHOUTcast-style
listeners.

Black Candy Store (the Rails app) keeps **all** authoritative domain state --
sequencing decisions, token validation, listener limits, and the concurrency
cap. It drives this service over a small loopback HTTP contract, exactly
mirroring the existing ``PlaybackSidecar`` seam:

    POST   /broadcasts                     -> spin up a broadcast for a station/session id
    DELETE /broadcasts/{id}                -> tear a broadcast down
    POST   /broadcasts/{id}/next           -> hand in the next resolved source (or continuity)
    GET    /broadcasts/{id}/status         -> encode position, listener count, uptime
    GET    /internal/broadcasts/{id}/listen -> the raw MP3 fan-out (loopback only)
    GET    /healthz                        -> liveness probe

The broadcaster holds **no authoritative domain state**: on restart Rails
re-establishes broadcasts from its own persisted state, and every "what plays
next" decision originates in the Rails Program_Sequencer. See README.md for the
full contract and configuration.
"""

__version__ = "1.0.0"
