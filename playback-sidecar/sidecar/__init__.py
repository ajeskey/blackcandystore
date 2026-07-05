"""Black Candy Store playback sidecar.

An out-of-process streaming output server that owns the AirPlay and Chromecast
wire protocols on behalf of the Black Candy Store Rails app. Rails keeps all
playback state and calls this service over a small local HTTP contract:

    GET  /devices  -> the Output_Devices currently advertised on the network
    POST /play     -> start streaming a resolved audio URL to a set of devices
    GET  /healthz  -> liveness probe

See README.md for the full contract and configuration.
"""

__version__ = "1.0.0"
