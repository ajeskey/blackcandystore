# Black Candy Store — Playback Sidecar

A small standalone **streaming output server** that lets Black Candy Store play
audio on **AirPlay** and **Chromecast** devices under the `server_playback`
playback mode.

Black Candy Store (the Rails app) owns all playback *state* — sessions, the
state machine, device cache, and stream resolution. It hands the actual
device/protocol work to this sidecar over a tiny local HTTP contract. This split
exists because there is no mature pure-Ruby AirPlay 2 / Chromecast sender stack,
so the wire protocols live here (Python, using `pyatv` and `pychromecast`).

> This is an optional component. Without it, everything else in Black Candy
> Store works; only server-side output to AirPlay/Chromecast is unavailable, and
> the UI degrades gracefully (the Playback Devices page shows an empty state).

## The contract

The Rails app talks to the sidecar at `PLAYBACK_SIDECAR_URL`
(default `http://127.0.0.1:9330`):

| Method & path | Purpose |
| --- | --- |
| `GET /healthz` | Liveness probe. |
| `GET /devices` | List devices currently advertised on the network. |
| `POST /play` | Start streaming a resolved audio URL to a set of devices. |

`GET /devices` returns:

```json
{ "devices": [
  { "identifier": "uuid-or-mdns-id", "name": "Living Room",
    "protocol": "airplay", "requires_password": false }
] }
```

`POST /play` receives (from Rails `PlaybackController#dispatch_audio`):

```json
{
  "device_ids": [3],
  "devices": [{ "id": 3, "identifier": "uuid-or-mdns-id", "protocol": "chromecast", "requires_password": false }],
  "stream_source": "local",
  "stream_url": "/stream/42",
  "stream_token": "<signed, song-scoped, short-lived token>",
  "credentials": { "3": "device-password" }
}
```

The sidecar builds the absolute fetch URL as
`BLACK_CANDY_URL + stream_url + "?stream_token=" + stream_token` and streams it
to each target device. Responses:

- `200` — playing (ack).
- `401` — a password-protected device's credential was missing/incorrect
  (Rails maps this to `device_authentication_error`).
- `404` — a requested device is not currently reachable.
- `502` — the device was reached but playback could not start.

## Configuration

All via environment variables:

| Variable | Default | Meaning |
| --- | --- | --- |
| `SIDECAR_HOST` | `0.0.0.0` | Bind address for the sidecar's HTTP server. |
| `SIDECAR_PORT` | `9330` | Port the sidecar listens on. |
| `BLACK_CANDY_URL` | `http://127.0.0.1:3000` | Where the sidecar fetches audio from the app. |
| `DISCOVERY_TIMEOUT` | `5.0` | Seconds to scan the network for devices. |
| `PLAY_TIMEOUT` | `15.0` | Seconds to wait connecting/commanding a device. |
| `PLAY_CONTENT_TYPE` | `audio/mpeg` | Content type advertised to Chromecast. |
| `LOG_LEVEL` | `INFO` | Log level. |

## Running

### Locally (development)

```shell
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
.venv/bin/python -m sidecar
```

### Docker

Device discovery uses mDNS/multicast, which does **not** cross Docker's default
bridge network. On Linux, use host networking:

```shell
docker build -t blackcandystore-sidecar .
docker run --network host -e BLACK_CANDY_URL=http://127.0.0.1:3000 blackcandystore-sidecar
```

On macOS/Windows, Docker host networking is unavailable, so run the sidecar
directly on the host (the local dev instructions above) for real device
discovery.

See the repo-root `docker-compose.yml` for running the app and sidecar together.

## Tests

```shell
.venv/bin/pip install -r requirements-dev.txt
.venv/bin/python -m pytest
```

The test suite stubs the protocol backends, so it runs without real hardware or
network access. **Discovery and playback against real AirPlay/Chromecast devices
require a hardware smoke test** — the protocol backends (`sidecar/backends/`)
are exercised against live devices, not in CI.
