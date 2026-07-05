# Server-side playback and the playback sidecar

_(Store)_ Black Candy Store adds a `server_playback` playback mode where the
**server** is the audio source and streams to AirPlay or Chromecast devices,
alongside the original `client_cast` mode where the browser/app casts directly.

Server-side output is handled by an optional out-of-process **playback sidecar**
that owns the AirPlay/Chromecast wire protocols. The Rails app keeps all
playback state and delegates the device work to the sidecar over a small local
HTTP contract.

## Architecture

```
┌────────────────────┐        HTTP (loopback)        ┌──────────────────────┐
│  Black Candy Store  │  GET /devices, POST /play  →  │   Playback Sidecar   │
│  (Rails)            │                               │   (pyatv,            │
│                     │  ← GET /stream/:id?token=…    │    pychromecast)     │
│  state machine,     │     (fetch audio to stream)   │                      │
│  sessions, cache    │                               │  AirPlay/Chromecast  │
└────────────────────┘                               └──────────┬───────────┘
                                                                 │ mDNS + audio
                                                          ┌──────▼───────┐
                                                          │ Speakers/TVs │
                                                          └──────────────┘
```

- **Discovery** — `DeviceDiscovery.discover` calls the sidecar's `GET /devices`
  and reconciles the `output_devices` cache. When the sidecar is absent it
  degrades to an empty set; nothing breaks.
- **Dispatch** — `PlaybackController#dispatch_audio` resolves the current Song's
  stream path and posts it to the sidecar's `POST /play` with device descriptors
  and a signed stream token.
- **Stream fetch** — the sidecar fetches the audio back from the app using the
  token (see below).

## The Rails ⇄ sidecar contract

The full request/response shapes are documented in
[`playback-sidecar/README.md`](../playback-sidecar/README.md). Key points:

- `POST /play` carries a `devices` array with each device's protocol-level
  `identifier` (Rails DB ids are meaningless off the server), plus a
  `stream_token`.
- Password-protected AirPlay devices require a per-device credential, keyed by
  the Rails Output_Device id. A missing/incorrect credential returns `401`.

## The signed stream token (security)

The sidecar has no login session, so it cannot use the normal cookie/token auth
to fetch `/stream/:id`. Instead, Rails mints a **signed, song-scoped,
short-lived token** (`Song#signed_id` with the `sidecar_stream` purpose, 6h TTL)
and includes it in the `/play` payload. The sidecar appends it when fetching the
audio.

The `SidecarStreamAccess` controller concern authorizes a stream request that
carries a valid token for the exact Song being fetched, and otherwise falls
through to the standard `require_login`. This path is deliberately narrow:

- It grants read access to **one Song's stream only**, for the life of the token.
- The token is HMAC-signed by the app secret and namespaced to a single purpose,
  so it is useless for any other Song or endpoint.
- Absent a token, authentication is unchanged.

## Configuration

| Variable | Where | Default | Meaning |
| --- | --- | --- | --- |
| `PLAYBACK_SIDECAR_URL` | Rails | `http://127.0.0.1:9330` | Where Rails reaches the sidecar. |
| `SERVER_BASE_URL` | Rails | `http://localhost:3000` | Public base URL of the app. |
| `BLACK_CANDY_URL` | Sidecar | `http://127.0.0.1:3000` | Where the sidecar fetches audio from. |

## Deployment notes

- AirPlay/Chromecast discovery relies on **mDNS/multicast**, which does not cross
  Docker's default bridge network. On Linux, run the sidecar (and app) with host
  networking. On macOS/Windows, run the sidecar directly on the host.
- The sidecar is **optional**. If you only use `client_cast` (browser/app
  casting) you do not need it.
- Chromecast needs an explicit content type; transcoded output (MP3) works out of
  the box. Configure `PLAY_CONTENT_TYPE` if you serve other formats.

See [`playback-sidecar/`](../playback-sidecar/) for the service, its tests, and
its Dockerfile.
