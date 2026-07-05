# Libraries

A library is a named collection of music content (songs, albums, and artists). A **local** library (`kind: "local"`) is backed by a media path on this server. A **remote** library (`kind: "remote"`) is hosted on another server and reached through an active connection that was established by redeeming an invite code; its catalog is browsed from a locally materialized mirror, so listing and browsing a remote library are served entirely from local queries with no live round-trip to the hosting server. (Audio and artwork for remote content still stream and proxy live at play time.)

Each user browses one library at a time — their **active library**. Browsing, searching, and listing results are scoped to the active library.

Creating, renaming, and deleting libraries is restricted to the server owner (an admin). Requests to those endpoints from a non-admin user are rejected with `403 Forbidden` and a JSON error body:

```json
{ "type": "Forbidden", "message": "..." }
```

## `GET /libraries`

Returns the libraries the current user can browse, alongside the content of their active library. The list contains every local library the user owns together with every remote library the user currently reaches through an active connection, ordered by name. A user with access to no libraries gets an empty list.

Each library in the list carries an `active` flag indicating whether it is the user's current active library, and the active library's own content is returned under `active_content` so a multi-library client can render both in one round trip. When the user has no active library, `active_library_id` is `null` and `active_content` collections are empty.

__Response:__

```json
{
  "libraries": [
    {
      "id": 1,
      "name": "Main Library",
      "kind": "local",
      "is_default": true,
      "scan_state": "idle",
      "active": true
    },
    {
      "id": 4,
      "name": "Jane's Shared Library",
      "kind": "remote",
      "is_default": false,
      "scan_state": "idle",
      "active": false
    }
  ],
  "active_library_id": 1,
  "active_content": {
    "albums": [
      { "id": 1, "name": "Sample Album", "year": 2024, "...": "..." }
    ],
    "artists": [
      { "id": 1, "name": "Sample Artist", "is_various": false, "...": "..." }
    ],
    "songs": [
      { "id": 1, "name": "Sample Song", "duration": 215.4, "...": "..." }
    ]
  }
}
```

The items under `active_content` use the same shapes as their resource sections: see [Albums](albums.md), [Artists](artists.md), and [Songs](songs.md).

Fields on each library object:

| Field | Type | Description |
|-------|------|-------------|
| `id` | integer | The library's id |
| `name` | string | The library's name |
| `kind` | string | `local` (hosted on this server) or `remote` (mirrored from another server) |
| `is_default` | boolean | Whether this is the default library derived from the pre-existing `MEDIA_PATH` collection |
| `scan_state` | string | Local scan status: `idle`, `syncing`, or `failed` |
| `active` | boolean | Whether this is the current user's active library |

## `GET /library`

Returns the active-library overview: a dashboard summarizing the content of the current user's active library. This endpoint renders an HTML page (there is no JSON representation); it lists the counts of albums, artists, playlists, and songs scoped to the active library, and reflects whether a local library scan is currently running. When the user has access to no libraries, the counts are zero.

## `POST /libraries`

Creates a local library. Server owner (admin) only.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `library[name]` | string | Yes | The library name; 1–255 characters and unique within the server (compared case-insensitively; surrounding whitespace is trimmed) |
| `library[media_path]` | string | Yes | Path on this server that the library's media is read from; must exist and be readable |
| `library[kind]` | string | No | Library kind; defaults to `local` |

__Response:__

Returns the created library object (same shape as an item in `GET /libraries`) with status `201 Created`:

```json
{
  "id": 5,
  "name": "Soundtracks",
  "kind": "local",
  "is_default": false,
  "scan_state": "idle",
  "active": false
}
```

__Validation errors:__

Invalid submissions are rejected with `422 Unprocessable Entity` and a JSON error body of the form `{ "type": "RecordInvalid", "message": "..." }`, leaving any existing library unchanged. Errors include:

- Name that is empty, whitespace-only, or longer than 255 characters.
- Name that duplicates an existing library's name.
- Media path that does not exist.
- Media path that exists but is not readable.
- Media path whose existence could not be verified (the check failed or timed out).

## `PATCH /libraries/:id`

Renames a library. Server owner (admin) only. Only the name is changed, so the library's existing content associations (songs, albums, artists) are preserved.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `library[name]` | string | Yes | The new name; 1–255 characters and unique within the server |

__Response:__

Returns the updated library object (same shape as `POST /libraries`). An invalid name is rejected with `422 Unprocessable Entity` (`{ "type": "RecordInvalid", "message": "..." }`) and leaves the library unchanged.

## `DELETE /libraries/:id`

Deletes a local library. Server owner (admin) only. Deletion removes the library's content associations — its songs are removed, and albums and artists are removed when no song remains associated with them (albums and artists that still have a song are preserved) — and deletes the library's access grants. Any user whose active library was the deleted library has that selection cleared.

__Response:__

Returns `204 No Content`.
