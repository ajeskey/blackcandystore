# Black Candy Store — Broadcaster

A small standalone **continuous stream assembly + fan-out server** that gives
Black Candy Store the always-on radio / co-listen data plane. It is a sibling of
the [`playback-sidecar/`](../playback-sidecar): where the sidecar owns the
AirPlay/Chromecast wire protocols, the broadcaster owns the continuous MP3
encode and Icecast/SHOUTcast-style listener fan-out.

For each active broadcast it runs an **ffmpeg-based constant-bitrate MP3 encode
loop** that advances in real time whether or not anyone is listening, and serves
that single shared encode position to **zero or more concurrent listeners** who
join mid-stream at the current position.

Black Candy Store (the Rails app) keeps **all** authoritative domain state —
which songs play (the Program_Sequencer), token validation, listener limits, and
the concurrency cap. The broadcaster holds **no authoritative domain state**: on
restart, Rails re-establishes broadcasts from its own persisted state, and every
"what plays next" decision originates in Rails.

> This is an internal, loopback-only component. It is never exposed publicly —
> Rails performs authorization once at connect time and reverse-proxies public
> listeners to the broadcaster's internal listen endpoint.

## The contract

Rails talks to the broadcaster at `BROADCASTER_URL` (default
`http://127.0.0.1:9340`):

| Method & path | Purpose |
| --- | --- |
| `GET /healthz` | Liveness probe. |
| `POST /broadcasts` | Spin up a broadcast for a station/session id; returns the internal stream handle. |
| `DELETE /broadcasts/:id` | Stop and tear down a broadcast. |
| `POST /broadcasts/:id/next` | Provide the next resolved source (song path + signed token, or continuity). |
| `GET /broadcasts/:id/status` | Current encode position, listener count, uptime. |
| `GET /internal/broadcasts/:id/listen` | The raw MP3 fan-out (loopback only). |

`POST /broadcasts` receives:

```json
{
  "id": "radio_station:42",
  "listener_limit": 50,
  "bitrate_kbps": 128,
  "initial_source": { "kind": "song", "source_url": "/stream/9", "stream_token": "<signed token>" }
}
```

and returns:

```json
{ "id": "radio_station:42", "listen_path": "/internal/broadcasts/radio_station:42/listen", "running": true }
```

`POST /broadcasts/:id/next` receives one resolved source (Rails' Program_Sequencer
decides what it is):

```json
{ "kind": "song", "source_url": "/stream/10", "stream_token": "<signed token>" }
```

or, when nothing is currently resolvable, a continuity directive that keeps the
stream open with silence until a song arrives:

```json
{ "kind": "continuity" }
```

`GET /broadcasts/:id/status` returns:

```json
{
  "id": "radio_station:42",
  "running": true,
  "position_seconds": 123.4,
  "listener_count": 3,
  "listener_limit": 50,
  "uptime_seconds": 456.7,
  "current_source_kind": "song"
}
```

Responses:

- `200 / 202` — accepted / queued.
- `404` — no broadcast with that id is running here (Rails re-establishes it if
  its own state says it should exist).
- `409` — a broadcast with that id is already running.
- `503` (on `listen`) — listener limit reached; the new connection is refused
  and existing listeners are not disturbed.

## How the continuous encode works

Each broadcast runs one ffmpeg process at a time, reading its input with `-re`
(native/real-time rate) and encoding to constant-bitrate MP3 on `pipe:1`. A
loop pumps ffmpeg's stdout into a fan-out that pushes each chunk to every
connected listener's bounded buffer:

- The encode **advances with zero listeners** — the loop always drains ffmpeg,
  so the wall-clock position keeps moving (Req 2.1, 2.6).
- A new listener attaches to the live fan-out and receives the **next** chunks,
  i.e. the **current position**, never the start of a song (Req 2.4, 3.2).
- When a song finishes and no next source is queued, the loop emits
  **Continuity_Audio** (silence) until Rails posts a song via `/next`
  (Req 2.5). A queued song interrupts continuity immediately.
- A listener that cannot keep up past its buffer is **dropped** (Icecast-style)
  rather than back-pressuring the shared encode — one slow client can never
  disturb the others (Req 11.7).
- The position is derived from encoded bytes at the constant bitrate, so
  `status` reports a meaningful wall-clock position for join + limit decisions.

## Configuration

All via environment variables:

| Variable | Default | Meaning |
| --- | --- | --- |
| `BROADCASTER_HOST` | `127.0.0.1` | Bind address. Loopback by design; set `0.0.0.0` only inside a container network. |
| `BROADCASTER_PORT` | `9340` | Port the broadcaster listens on. |
| `BLACK_CANDY_URL` | `http://127.0.0.1:3000` | Where the broadcaster fetches source audio from. |
| `BITRATE_KBPS` | `128` | Constant MP3 bitrate for every broadcast. |
| `SAMPLE_RATE` | `44100` | Encode sample rate. |
| `CHANNELS` | `2` | Encode channel count. |
| `FFMPEG_BINARY` | `ffmpeg` | ffmpeg executable. |
| `CHUNK_SIZE` | `4096` | Bytes read per fan-out chunk. |
| `LISTENER_BUFFER_CHUNKS` | `256` | Per-listener buffered chunks before a slow client is dropped. |
| `LOG_LEVEL` | `INFO` | Log level. |

## Running

### Locally (development)

```shell
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
.venv/bin/python -m broadcaster
```

Requires `ffmpeg` on `PATH` for real encoding.

### Docker

```shell
docker build -t blackcandystore-broadcaster .
docker run -e BLACK_CANDY_URL=http://127.0.0.1:3000 blackcandystore-broadcaster
```

See the repo-root compose file for running the app and its companion services
together.

## Tests

```shell
.venv/bin/pip install -r requirements-dev.txt
.venv/bin/python -m pytest
```

The test suite injects a **fake encoder** in place of ffmpeg, so it exercises
the encode loop, fan-out, listener accounting, and the full HTTP contract
without real audio or an ffmpeg install. **Real ffmpeg encoding and byte-level
timing require a smoke test** against a running Rails instance — the ffmpeg
integration (`broadcaster/encoder.py`) is exercised against live sources, not in
CI.
