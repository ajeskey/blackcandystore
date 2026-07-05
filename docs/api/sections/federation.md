# Federation API (server-to-server)

The Federation API is Black Candy's **cross-server protocol**. It is not the client/app API — browsers and the native players never call it. Instead, one Black Candy server (the **redeeming server**) calls it against another Black Candy server (the **hosting server**) to browse, synchronize, and stream a library that has been shared across servers.

All federation endpoints live under the `/federation` namespace and are token-authenticated server-to-server: the redeemer presents an `Access_Grant` secret token as `Authorization: Bearer <grant_token>` rather than using the app's cookie/session authentication. Because there is no browser session, these endpoints skip the normal login requirement and CSRF protection. Each content endpoint serves **only local, authorized content** scoped to the single library the presented grant references.

## The hybrid sync model

A redeeming server keeps a **metadata-only catalog mirror** of a remote library — the songs, albums, and artists as local rows, with names, durations, track/disc numbers, associations, and the stable hosting-side identifiers. It stores **no audio bytes and no artwork bytes**. Audio and artwork are proxied **live** at request time through the Federation API.

Synchronization is a **pull backbone plus a best-effort push nudge**:

- **Pull backbone (source of correctness).** The redeemer runs a full sync when a connection is first established, then periodically pulls "changes since a cursor." The scheduled pull always converges the mirror.
- **Best-effort nudge (optimization only).** When a hosting library's catalog changes, the host fires a best-effort `POST /nudges` at each registered redeemer so it can pull immediately instead of waiting for its next scheduled poll. Because a redeemer may be behind NAT, nudge delivery can fail; **correctness never depends on a nudge landing**. Whether or not a nudge ever arrives, the scheduled pull reconciles.

## Authentication

Every hosting-side federation request is authorized by an `Access_Grant` secret token presented as:

```
Authorization: Bearer <grant_token>
```

(The hosting side also accepts the `Token <grant_token>` scheme.)

Authorization is performed by `Federation::BaseController#authorize_federation!(library_id)`, which:

1. Looks up the `Access_Grant` matching the presented token. No match → `403`.
2. Requires the grant to be **usable** — active, not revoked, and not expired. Otherwise → `403`.
3. Requires the grant to **reference the requested library** (`grant.library_id == library_id`). Otherwise → `403`.
4. As defense-in-depth, requires the referenced library to still exist and be **local** to this server (`Library.local`). A credential match alone is never sufficient. Otherwise → `403`.

Any authorization failure raises `BlackCandy::Forbidden`, which is rendered as `403`. A `403` on the changes endpoint is the redeemer's **teardown signal** — the redeeming client maps `401`/`403` to an `Unauthorized` error and marks the mirror unavailable.

The `POST /nudges` endpoint (received on the redeeming side) is authenticated differently: its only credential is the opaque per-connection `nudge_token` carried in the request body. See the endpoint reference below.

## Endpoint reference

All hosting calls use HTTPS and the `Authorization: Bearer <grant_token>` credential under the `/federation` namespace. The redeeming client (`Federation::Client`) applies two timeout budgets, matching this contract:

- `GRANT_TIMEOUT` = **30s** for redemption / grant confirmation.
- `CONTENT_TIMEOUT` = **10s** for content (browse, changes, stream, asset, ping).

Both are applied to open **and** read timeouts, so neither connection setup nor a stalled response can exceed the budget.

| Purpose | Method & Path | Direction | Auth | Request | Response |
|---|---|---|---|---|---|
| Confirm grant (redemption) | `POST /federation/grants/confirm` | redeemer → host | Bearer grant token | `{ library_id, nudge_callback_url?, nudge_token? }` | `200 { library: { id, name }, valid: true }` or `403` |
| Browse songs | `GET /federation/libraries/:library_id/songs` | redeemer → host | Bearer grant token | `?page=<int>` (pagination) | `200` array of song objects (same shape as local browsing) or `403` |
| Browse albums | `GET /federation/libraries/:library_id/albums` | redeemer → host | Bearer grant token | `?page=<int>` (pagination) | `200` array of album objects or `403` |
| Browse artists | `GET /federation/libraries/:library_id/artists` | redeemer → host | Bearer grant token | `?page=<int>` (pagination) | `200` array of artist objects or `403` |
| Changes since cursor | `GET /federation/libraries/:library_id/changes` | redeemer → host | Bearer grant token | `?cursor=<int>&page=<int>` | `200 { catalog_version, full_sync_required, changes: [...] }` or `403` |
| Stream a song | `GET /federation/libraries/:library_id/songs/:song_id/stream` | redeemer → host | Bearer grant token | optional `Range` header | `200`/`206` audio bytes (range-capable) or `403` |
| Album cover asset | `GET /federation/libraries/:library_id/albums/:id/asset` | redeemer → host | Bearer grant token | `?variant=small\|medium\|large` (optional) | `200` image bytes, `404` if no cover, or `403` |
| Artist image asset | `GET /federation/libraries/:library_id/artists/:id/asset` | redeemer → host | Bearer grant token | `?variant=small\|medium\|large` (optional) | `200` image bytes, `404` if no image, or `403` |
| Health / liveness | `GET /federation/ping` | redeemer → host | Bearer grant token | — | `200` (no body) |
| Catalog nudge | `POST /nudges` | host → redeemer | `nudge_token` (opaque, per-connection) | `{ nudge_token }` | `204` (accepted or ignored — never leaks whether a connection exists) |

Notes on individual endpoints:

- **`grants/confirm`** is called at redemption time to confirm the presented token is valid and references a given local library before the redeemer creates a `Library_Connection`. It also piggy-backs **nudge registration**: when the request supplies a `nudge_callback_url` (and optionally a `nudge_token`), the host persists them on the matched `Access_Grant` so it can later nudge that redeemer. Both fields are optional; a grant without a callback simply receives no nudges and relies on the redeemer's scheduled pull.
- **Browse endpoints** return exactly the same JSON shapes as local browsing (they render the reused `songs`/`albums`/`artists` index templates), scoped strictly to the authorized local library. The per-user "favorited" flag has no meaning cross-server and is emitted as `false`. Responses carry the standard pagination headers.
- **Stream** mirrors the local streaming logic: HTTP range support via `Rack::Files`, or `X-Sendfile` when Thruster is enabled. The song is scoped strictly to the authorized local library.
- **Asset** serves cover-image bytes for an album or artist scoped to the authorized local library. An optional `variant` (`small`, `medium`, or `large`) selects a processed variant; otherwise the original attachment is returned. A record with **no cover image answers `404`**, so the redeemer can resolve the asset as absent.
- **`ping`** answers `200` without touching any library content, so a redeemer can confirm reachability within a timeout budget independently of any specific library request.
- **`POST /nudges`** is received on the redeeming side (top-level path, not under `/federation`). It inherits from `ActionController::API`, so it has no session auth or CSRF to skip. It looks up the redeemer's own `LibraryConnection` by `nudge_token`; a match on an **active** connection enqueues an immediate incremental sync, and an unknown or inactive token is ignored. It **always returns `204`**, never disclosing whether a connection exists for a given token.

## Changes_Since API

The Changes_Since API is the incremental backbone. It returns the ordered catalog changes for a library that occurred **after** a cursor, together with the catalog version the redeemer should adopt once it applies them.

### Request

```
GET /federation/libraries/:library_id/changes?cursor=<int>&page=<int>
Authorization: Bearer <grant_token>
```

- `cursor` — the redeemer's recorded `Sync_Cursor` (the highest catalog version it has already applied). Defaults to `0`.
- `page` — the page of the paginated delta. Defaults to `1`.

### Response

```json
{
  "catalog_version": 42,
  "full_sync_required": false,
  "changes": [
    {
      "change_type": "upsert",
      "item_type": "song",
      "id": 123,
      "...": "full metadata + associations (see below)"
    },
    {
      "change_type": "deletion",
      "item_type": "album",
      "id": 77
    }
  ]
}
```

Top-level fields (from `app/views/federation/changes/index.json.jbuilder`):

- **`catalog_version`** — the version the redeemer adopts as its new `Sync_Cursor` once it applies `changes`. This is the hosting library's current `catalog_version`.
- **`full_sync_required`** — a boolean. When `true`, `changes` is empty and the redeemer must fall back to a full sync (see below).
- **`changes`** — an ordered array of change entries. Each entry always carries:
  - **`change_type`** — `"upsert"` or `"deletion"`.
  - **`item_type`** — `"song"`, `"album"`, or `"artist"`.
  - **`id`** — the item's hosting-side id.

For an **upsert**, the entry additionally carries the item's full metadata and associations, merged in from the exact same jbuilder shapes local browsing produces (so the mirror receives an identical field set):

- **song upsert** — `id`, `name`, `duration`, `album_id`, `artist_id`, `url`, `stream_source`, `resolved_stream_path`, `available`, `album_name`, `artist_name`, `is_favorited` (always `false` cross-server), `format`, and `album_image_urls` (`small`/`medium`/`large`).
- **album upsert** — `id`, `name`, `year`, `genre`, `artist_id`, `artist_name`, `image_urls` (`small`/`medium`/`large`), `asset_source`, `resolved_asset_path`.
- **artist upsert** — `id`, `name`, `is_various`, `image_urls` (`small`/`medium`/`large`), `asset_source`, `resolved_asset_path`.

A **deletion** entry is fully described by `change_type`, `item_type`, and `id` alone — it carries no metadata, because the underlying row is already gone on the host.

> The redeeming apply step (`CatalogSync.apply`) consumes the subset of upsert fields it needs to mirror metadata and resolve associations by hosting-side id: for a song `name`, `duration`, `tracknum`, `discnum`, `album_id`, `artist_id`; for an album `name`, `year`, `genre`, `artist_id`; for an artist `name`, `is_various`. It resolves each `album_id`/`artist_id` to the mirrored row carrying the matching hosting-side id.

### Boundary behavior

- **Empty set at or beyond the current version (`cursor >= catalog_version`).** There is nothing after the cursor, so the response returns an empty `changes` set with `full_sync_required: false` and the current `catalog_version`. A page past the last one likewise returns an empty set.
- **Below the retained floor (`full_sync_required`).** The host retains its change log down to a floor version; older rows may be compacted away. If the cursor is below the oldest retained change (the deltas the redeemer still needs have been compacted), the host **cannot serve that cursor incrementally**. It returns `full_sync_required: true` with an empty `changes` set and no partial delta, signalling the redeemer to rebuild the whole mirror.

## Synchronization lifecycle

The hosting side records changes and the redeeming side applies them. On the host, every catalog change originating in the scan pipeline atomically bumps the library's `catalog_version` and appends exactly one `catalog_changes` row stamped with the new version (`CatalogVersioning`), then enqueues a best-effort nudge. On the redeemer, `CatalogSync` drives the mirror:

1. **First-connection full sync.** When redemption creates a **new** `Library_Connection`, it enqueues a `CatalogSyncJob(connection.id, mode: :full)`. The full sync browses the host's entire catalog (artists, then albums, then songs, paged), rebuilds the mirror to exactly that set (removing any mirrored row whose hosting-side id is absent from the fetched catalog), and adopts the host's `catalog_version` as the `Sync_Cursor`. Re-redemption that reuses an existing connection does **not** re-trigger a full sync.

2. **Scheduled incremental sync.** A SolidQueue recurring task (`config/recurring.yml`) runs `CatalogSyncJob.enqueue_all_active` every `Poll_Interval`, enqueueing one incremental sync per active connection. An incremental sync requests only the changes after the recorded cursor, collects every page of the delta, applies them, and advances the cursor to the returned `catalog_version` — all within a single transaction so a partial mirror never commits with an advanced cursor. If the host responds with `full_sync_required: true`, the incremental sync falls back to a full sync, reusing the version the host already reported.

3. **Best-effort nudge.** After a hosting library's catalog change commits, `CatalogNudgeJob` POSTs `{ nudge_token }` to each active grant's registered `nudge_callback_url` (fire-and-forget, short timeout, no indefinite retry). The redeemer's `NudgesController` looks up the connection by `nudge_token` and enqueues an immediate incremental sync. This only accelerates convergence; the scheduled pull would reconcile regardless.

4. **Stale handling on transport failure.** If a sync hits an `Unreachable` or `Timeout` error (host down, DNS/TLS/socket failure, or no response within `CONTENT_TIMEOUT`), the fetch happens before the transaction opens, so the last-known mirror and the `Sync_Cursor` are left untouched. The connection's `sync_state` is marked `stale` and keeps serving, surfacing staleness rather than wiping the mirror.

5. **Teardown on authorization error.** If a sync hits an `Unauthorized` error (`401`/`403`, e.g. the grant was revoked or expired mid-use), the mirror is torn down: the connection's `status` becomes `revoked` and its `sync_state` becomes `unavailable`. Rather than deleting rows, the mirror is marked unavailable so it stops being browsable or served. This touches only the affected connection's own row; every other connection's mirror is untouched (all mirrored content is `library_id`-scoped). Deleting the connection entirely cascades the remote library's content cleanup through the existing library-teardown path.

## Configuration

Two environment variables govern federation on each server:

- **`SERVER_BASE_URL`** — the current server's public base URL (backs `BlackCandy.config.server_base_url`, default `http://localhost:3000`). It is encoded into every invite code so a redeeming server knows how to reach this server, and it is used at redemption to build this server's own nudge callback URL as `<SERVER_BASE_URL>/nudges`, which the redeemer registers with the host during `grants/confirm`.
- **`CATALOG_SYNC_POLL_INTERVAL`** — the `Poll_Interval` in **minutes** between scheduled incremental syncs for each active connection (backs `BlackCandy.config.catalog_sync_poll_interval`, **default 15**). It is consumed by the Sync_Scheduler recurring task in `config/recurring.yml`, which renders its schedule as `every <interval> minutes`.
