# Playback & source preference

These endpoints control how a user streams and plays content when the same content is available from more than one library or server. They cover three related settings, each stored per user and always applied to the authenticated user:

- **Source preference** — when a song exists in more than one accessible library/server, which copy to stream.
- **Playback mode** — whether the client casts audio directly (`client_cast`) or the server plays audio to an output device (`server_playback`). The two modes are mutually exclusive.
- **Cast session** — the bookkeeping record that mirrors and drives the `client_cast` session state machine.

Because each setting always belongs to the current user, these are singular resources with no id in the path.

## `GET /source_preference`

Returns the current user's source preference.

__Response:__

```json
{
  "source_preference": "prefer_own_server"
}
```

The value is one of `prefer_own_server` or `prefer_highest_quality`. When a song's content is reachable from more than one accessible source, this preference chooses which copy is resolved for streaming; if the preferred copy is unavailable, resolution falls back to the next available source.

## `PATCH /source_preference`

Updates the current user's source preference.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `source_preference` | string | Yes | One of `prefer_own_server` or `prefer_highest_quality` |

__Response:__

Returns the updated value in the same shape as `GET /source_preference`.

```json
{
  "source_preference": "prefer_highest_quality"
}
```

A value other than the two supported options is rejected as a validation error (`422 Unprocessable Entity` for JSON clients) and the existing preference is left unchanged.

## `GET /playback_mode`

Returns the current user's playback mode, along with the resolved audio source and the session kind that manages playback activity under that mode.

__Response:__

```json
{
  "playback_mode": "client_cast",
  "audio_source": "client",
  "managed_by": "cast_session"
}
```

| Field | Description |
|-------|-------------|
| `playback_mode` | `client_cast` or `server_playback` |
| `audio_source` | Which end is the audio source: `client` under `client_cast`, `server` under `server_playback` |
| `managed_by` | The session kind that manages activity under this mode: `cast_session` under `client_cast`, `playback_session` under `server_playback` |

## `PATCH /playback_mode`

Selects the current user's playback mode.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `playback_mode` | string | Yes | One of `client_cast` or `server_playback` |

__Response:__

Returns the updated mode in the same shape as `GET /playback_mode`.

```json
{
  "playback_mode": "server_playback",
  "audio_source": "server",
  "managed_by": "playback_session"
}
```

A value other than the two supported options is rejected as a validation error (`422 Unprocessable Entity`) and the existing mode is left unchanged.

**Mode exclusivity:** the two modes are mutually exclusive — no activity is ever managed by both a cast session and a server playback session at the same time. Successfully changing the mode tears down the other mode's session (stopping it) so only the selected mode's session manages playback.

## `GET /cast_session`

Returns the current state of the user's `client_cast` cast session. This record is a server-side mirror of the client-side cast state; the actual casting/streaming to the device happens on the client.

__Response:__

```json
{
  "state": "playing",
  "current_song_id": 1,
  "target_output_device_id": 42,
  "position": 87.5
}
```

| Field | Description |
|-------|-------------|
| `state` | One of `stopped`, `playing`, or `paused` |
| `current_song_id` | The song currently being cast, or `null` |
| `target_output_device_id` | The output device being cast to, or `null` |
| `position` | The current playback position |

## `POST /cast_session`

Creates or updates the bookkeeping record: selects the target output device to cast to and, optionally, the current song and starting position. This does not change the cast state on its own.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `target_output_device_id` | integer | No | The output device to cast to |
| `current_song_id` | integer | No | The song to cast |
| `position` | number | No | The starting playback position |

Only the parameters actually supplied are applied.

__Response:__

Returns the cast session in the same shape as `GET /cast_session` with status `201 Created`.

```json
{
  "state": "stopped",
  "current_song_id": 1,
  "target_output_device_id": 42,
  "position": 0
}
```

## `POST /cast_session/play`

Begins (or restarts) casting the current song and moves the session to `playing`.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `current_song_id` | integer | No | The song to cast; when omitted the existing current song is retained |
| `position` | number | No | The starting playback position; when omitted the existing position is retained |

__Response:__

Returns the updated cast session in the same shape as `GET /cast_session`.

```json
{
  "state": "playing",
  "current_song_id": 1,
  "target_output_device_id": 42,
  "position": 0
}
```

A play with no target output device is rejected: the persisted state is left unchanged and a `422 Unprocessable Entity` is returned.

```json
{
  "type": "CastTransitionRejected",
  "message": "Cast operation was rejected and the session state is unchanged."
}
```

## `POST /cast_session/resume`

Resumes a paused session back to `playing`, retaining the current song and playback position. Takes no parameters.

__Response:__

Returns the updated cast session in the same shape as `GET /cast_session`. A resume with no target output device is rejected with the same `422` `CastTransitionRejected` response as `play`.

## `POST /cast_session/pause`

Pauses a `playing` session, retaining the current song and playback position so a following resume continues from the same point. Takes no parameters. Pause is only defined from the `playing` state; from any other state it is rejected.

__Response:__

Returns the updated cast session in the same shape as `GET /cast_session`. When the transition is rejected, the persisted state is left unchanged and a `422` `CastTransitionRejected` response is returned.

## `POST /cast_session/stop`

Stops the session and clears the playback position. The session moves to `stopped` and `position` is reset to `0`. Takes no parameters.

__Response:__

Returns the updated cast session in the same shape as `GET /cast_session`.

```json
{
  "state": "stopped",
  "current_song_id": 1,
  "target_output_device_id": 42,
  "position": 0
}
```

## Streaming source resolution

Each song in the API carries where its audio is served from, resolved at the edge so the players never need library-specific logic. In addition to the legacy `url` field (preserved unchanged for backward compatibility), every song JSON includes:

| Field | Type | Description |
|-------|------|-------------|
| `stream_source` | string | `local` when the song lives in a local library on the current server, or `remote` when it lives in a remote library reached through a library connection |
| `resolved_stream_path` | string | The same-origin path the player fetches audio from. For a local song this is the current-server stream path; for a reachable remote song it is a same-origin proxy path (`/stream/remote/{song_id}`). Empty when a remote song's connection cannot be resolved |
| `available` | boolean | `true` when the source could be resolved; `false` when a remote song's library connection is unavailable (in which case `resolved_stream_path` is empty and the other fields are left untouched) |

Example song JSON (see [Songs](songs.md) for the full shape):

```json
{
  "id": 1,
  "name": "Sample Song",
  "duration": 215.4,
  "album_id": 1,
  "artist_id": 1,
  "url": "https://blackcandy.example.com/stream/new?song_id=1",
  "stream_source": "local",
  "resolved_stream_path": "/stream/new?song_id=1",
  "available": true,
  "album_name": "Sample Album",
  "artist_name": "Sample Artist",
  "is_favorited": false,
  "format": "mp3",
  "album_image_urls": { "small": "...", "medium": "...", "large": "..." }
}
```

When the same content is reachable from more than one accessible source, the copy chosen by the user's source preference (above) is the one resolved for streaming.
