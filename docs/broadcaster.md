# Radio, Co-listen, and the broadcaster service

_(Store)_ Black Candy Store adds always-on **Radio Stations** and collaborative
**Co-listen sessions**: continuous, listener-independent MP3 streams that a web
player or any generic Icecast/SHOUTcast client can tune into. Assembling a
continuous stream that keeps running with zero listeners does not fit inside the
normal Rails request cycle, so this work is handled by an out-of-process
companion — the **broadcaster** — that you run alongside the app.

This guide is for operators running Black Candy Store. It covers what the
broadcaster is, how to run it, and how stations and sessions actually stream.

> The broadcaster is only needed for Radio Stations and Co-listen sessions. If
> you do not use those features you do not need to run it, and the rest of the
> app is unaffected. Party Mode plays to output devices through the
> [playback sidecar](playback-sidecar.md), not the broadcaster.

## What the broadcaster is

The broadcaster is a small standalone **continuous stream assembly + fan-out
server**. It is a sibling of the [playback sidecar](playback-sidecar.md): where
the sidecar owns the AirPlay/Chromecast wire protocols for server-side output,
the broadcaster owns the continuous MP3 encode and the Icecast/SHOUTcast-style
listener fan-out that Radio and Co-listen need.

For each active broadcast it runs an **ffmpeg-based constant-bitrate MP3 encode
loop** that advances in real time whether or not anyone is listening — just like
a real radio station. Listeners join mid-stream at the **current position**,
never at the start of a song, and one shared encode is fanned out to zero or
more concurrent listeners.

The division of labor mirrors the sidecar seam exactly:

- **Rails is the control plane.** It owns all authoritative state: which songs
  play (the program sequencer), token validation, listener limits, the
  concurrency cap, and every lifecycle decision. Rails decides *what* plays and
  *who* may listen.
- **The broadcaster is the data plane.** It does the continuous encoding and
  byte fan-out and holds **no authoritative domain state**. Every "what plays
  next" decision originates in Rails, and on restart Rails re-establishes
  broadcasts from its own persisted state.

Because the broadcaster runs the stream out of process, it **must be running
alongside the app** for Radio Stations and Co-listen sessions to stream. If it
is not running, station and session streaming is unavailable while the rest of
the app keeps working normally (Req 3.1).

## Architecture

```
┌──────────────────────┐      HTTP (loopback)       ┌──────────────────────┐
│  Black Candy Store    │  POST /broadcasts       →  │     Broadcaster       │
│  (Rails)              │  POST /broadcasts/:id/next │  (ffmpeg encode loop  │
│                       │  DELETE /broadcasts/:id    │   + listener fan-out) │
│  program sequencer,   │                            │                       │
│  tokens, listener     │  ← GET /stream/:id?token=… │  continuous MP3,      │
│  limits, concurrency  │     (fetch source audio)   │  Icecast-style        │
│  cap, lifecycle       │                            │  fan-out              │
└──────────┬───────────┘                            └──────────┬───────────┘
           │ reverse-proxy listener bytes                       │
           │ (auth done once at connect time)                  │
      ┌────▼─────────────────────────────────────────────┐     │
      │  Listener (Web Player / generic MP3 client)        │◄────┘
      └───────────────────────────────────────────────────┘
```

Rails performs authorization once at connect time, then reverse-proxies the
listener's byte stream from the broadcaster's internal listen endpoint. This
keeps a single authenticated public surface, keeps the broadcaster bound to
loopback, and keeps listener-limit accounting authoritative in one place.

The full Rails ⇄ broadcaster control contract (the `POST /broadcasts`,
`DELETE /broadcasts/:id`, `POST /broadcasts/:id/next`, `GET
/broadcasts/:id/status` shapes) is documented in
[`broadcaster/README.md`](../broadcaster/README.md).

## Running the broadcaster

The broadcaster fetches source audio from the app, so it needs `BLACK_CANDY_URL`
pointed at your Rails instance, and it needs **ffmpeg** on `PATH` for real
encoding.

### Locally (development)

`bin/dev` starts everything via `Procfile.dev`, which already includes a
`broadcaster` entry:

```
broadcaster: cd broadcaster && .venv/bin/python -m broadcaster
```

Set up its virtualenv once:

```shell
cd broadcaster
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
```

After that, `./bin/dev` runs the broadcaster alongside the web, JS, and CSS
processes. To run it on its own:

```shell
cd broadcaster && .venv/bin/python -m broadcaster
```

### With Docker Compose

The repo-root [`docker-compose.sidecar.yml`](../docker-compose.sidecar.yml)
example runs the app together with both companion services (the playback sidecar
and the broadcaster):

```shell
docker compose -f docker-compose.sidecar.yml up
```

The `broadcaster` service builds from [`broadcaster/`](../broadcaster/) and runs
under host networking so the app can reach it on loopback.

### Configuration

The app finds the broadcaster through one environment variable; the broadcaster
itself has its own set (all documented in
[`broadcaster/README.md`](../broadcaster/README.md)):

| Variable | Where | Default | Meaning |
| --- | --- | --- | --- |
| `BROADCASTER_URL` | Rails | `http://127.0.0.1:9340` | Base URL where Rails reaches the broadcaster. Loopback by default, mirroring `PLAYBACK_SIDECAR_URL`. |
| `BROADCASTER_HOST` | Broadcaster | `127.0.0.1` | Bind address. Loopback by design; set `0.0.0.0` only inside a container network. |
| `BROADCASTER_PORT` | Broadcaster | `9340` | Port the broadcaster listens on. |
| `BLACK_CANDY_URL` | Broadcaster | `http://127.0.0.1:3000` | Where the broadcaster fetches source audio from. |
| `BITRATE_KBPS` | Broadcaster | `128` | Constant MP3 bitrate for every broadcast. |

The broadcaster **binds loopback** and is never exposed publicly. Rails is the
only public surface: it authorizes each listener once at connect time and
reverse-proxies the audio, so you do not open the broadcaster's port to the
internet.

## How Radio Stations and Co-listen sessions stream

### The Stream Endpoint

Every Radio Station and every Co-listen session has a **Stream Endpoint** URL,
and that URL exists **regardless of the station's or session's state** — it is
present through the API and UI whether or not anything is currently broadcasting
(Req 9.6). What changes with state is whether the endpoint delivers audio:

- A Radio Station serves audio only while it is **started**; a Co-listen session
  serves audio only while it is **active**.
- A request to a station that is not started (or a session that is not active)
  returns a **not-broadcasting** response (503) rather than audio.

For a station, the Stream Endpoint accepts the `.mp3` extension that generic
Icecast/SHOUTcast clients and hardware internet radios expect.

> Party Sessions are the exception: they do **not** expose a Stream Endpoint,
> because a party plays to host-selected output devices rather than to
> per-listener streams (Req 9.7).

### Visibility and tokens

Generic MP3 clients cannot send cookies or `Authorization` headers, so
authenticated streams are authorized by a token embedded in the URL. A Radio
Station's **Stream Visibility** decides which credentials a listener needs:

- **`public`** — the endpoint is served to any client with no credentials.
- **`authenticated`** (the default) — the request must present either a valid
  **Stream Token** embedded in the URL (`…/stream.mp3?token=…`), or a valid
  session cookie / Bearer credential for an account authorized to the station.

The Stream Token is scoped to the station, persisted only as a keyed digest
(never in plaintext), and the owning user or an admin can **rotate or revoke**
it at any time; a rotated or revoked token stops authorizing immediately.

**Co-listen sessions are never public.** A co-listen stream is authorized by a
**guest-derived stream token** unique to each participant, derived from that
participant's guest token and scoped to the session and its shared libraries.
Because it is derived from the guest's access, it invalidates automatically when
that access ends — through session expiry, revocation, guest removal, or session
teardown.

### Listener limits and concurrency

Two separate limits shape streaming, and both stay authoritative in Rails:

- **Listener Limit** — the owner- or admin-configured maximum number of
  concurrent listeners for a single station or session. When a new listener
  connects to a stream that is already at its limit, the connection is refused
  with a capacity response and the listeners already connected are **not**
  disturbed.
- **`max_concurrent_streams`** — a global admin setting (under Settings) that
  caps how many broadcasts may run concurrently across the whole server, since
  an always-on stream consumes resources even with zero listeners. It is
  enforced when a station is started or a session is activated: if starting
  would exceed the cap, the request fails with a capacity error and the state is
  left unchanged. It defaults to unbounded (no limit).

### Restart and resume

Because the broadcaster holds no authoritative state, a restart of either
process does not lose track of what should be playing. On boot, Rails is the
source of truth: a boot-time job re-establishes every **started** Radio Station
and every **active**, non-expired Co-listen session on the broadcaster, up to
the `max_concurrent_streams` cap. Sessions whose duration has expired are treated
as ended and are not resumed. The resume work is enqueued in the background, so
a slow or unavailable broadcaster never blocks the app from booting.

## See also

- [`broadcaster/README.md`](../broadcaster/README.md) — the service itself, its
  full control contract, its own configuration, and its tests.
- [Server-side playback and the playback sidecar](playback-sidecar.md) — the
  broadcaster's sibling service for Party Mode output to AirPlay/Chromecast.
