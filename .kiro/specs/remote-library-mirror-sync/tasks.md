# Implementation Plan: Remote Library Mirror Sync

## Overview

This plan completes the last mile of the shipped **multi-server-library-sharing** platform: a metadata-only Catalog_Mirror with hybrid (pull-backbone + best-effort nudge) synchronization. Work is organized under the four phases of the design's Phased Delivery Plan; each phase is independently shippable and leaves the system working.

Within each phase, tasks are sequenced migrations → models → services → controllers → wiring so each step builds on the last with no orphaned code. Every task grounds itself in existing components named in the design rather than reinventing them: the `Media.sync` / `Media.clean_up` scan pipeline, `Federation::Client`, `Federation::BaseController#authorize_federation!` / `LibraryAccess`, `Path_Resolver`, `RemoteStreamController`, `InviteManager#find_or_create_connection`, `Library#destroy_scoped_content`, and the `Song`/`Album`/`Artist`/`LibraryConnection`/`AccessGrant` models.

Testing follows the design's dual approach:
- **Property-based tests** cover the 15 correctness properties. The project uses **Minitest + rantly**; each property test reuses the existing `check_property` harness at `test/support/property_helper.rb` (no new generator or runner is hand-rolled), runs a **minimum of 100 iterations**, and is tagged with a comment in the exact format `# Feature: remote-library-mirror-sync, Property {number}: {property_text}`.
- **Integration / smoke tests** (using `WebMock` / stubbed hosting servers) cover the protocol and network paths the design explicitly marks NOT property-testable: the Changes_Since_API round trip, nudge delivery and its no-retry behavior, the live audio proxy, the live artwork proxy, scheduler timing, and the timeout budget.

All new columns are additive and nullable; the `Song` file-column validations are relaxed conditionally on `local?` libraries so existing local content is untouched. The plan MUST NOT break the DAAP/RSP local-only rule nor the existing 843 passing tests; each phase ends with a checkpoint that runs the full suite.

---

## Phase 1 — Hosting-side catalog versioning and changes-since
**Requirements: 3. Properties: 1, 2, 3.**
Delivers a host that tracks a monotonic Catalog_Version and serves incremental deltas over the Federation API. No redeemer behavior yet.

## Tasks

- [x] 1. Hosting-side catalog-version schema and change log
  - [x] 1.1 Add `catalog_version` to libraries and create the `catalog_changes` table
    - Migration (additive): add `catalog_version` integer, default 0, `null: false` to `libraries`
    - Create `catalog_changes` (`library_id` fk libraries, `version` integer `null: false`, `item_type` string `null: false` (`song｜album｜artist`), `item_id` integer `null: false`, `change_type` string `null: false` (`upsert｜deletion`), `created_at`)
    - Add index on `(library_id, version)` for ordered, paginated `changes_since` queries
    - _Requirements: 3.1, 3.4, 3.5_

- [x] 2. Catalog_Version bumping and change-log recording
  - [x] 2.1 Implement the `CatalogVersioning` module
    - Create `app/models/catalog_versioning.rb` with `record_upsert(item)` and `record_deletion(type:, remote_id:, library:)`: bump the owning local library's `catalog_version` and append one `CatalogChange` row stamped with the new version; upserts store id/type, deletions store id/type
    - _Requirements: 3.1, 3.4, 3.5_

  - [x] 2.2 Write property test for Catalog_Version monotonicity
    - `# Feature: remote-library-mirror-sync, Property 1: Catalog_Version is monotonically non-decreasing and strictly increases on change`
    - Generate random sequences of catalog changes (additions, metadata updates, deletions); assert `catalog_version` never decreases across the sequence and strictly increases on every change
    - **Validates: Requirements 3.1** (Property 1), min 100 iterations
    - _Requirements: 3.1_

  - [x] 2.3 Wire the bump hook into the scan pipeline
    - Instrument `Media.sync` (`:added`, `:modified`, `:removed`) and the album/artist orphan cleanup in `Media.clean_up` to call `CatalogVersioning` after the content change commits, resolving the bump per Local_Library from the existing `library_id`
    - _Requirements: 3.1, 3.4, 3.5_

  - [x] 2.4 Write unit tests for bump-hook wiring
    - Assert an addition, a metadata update, a removal, and an orphan cleanup each bump the version once and append the correctly-typed `CatalogChange` row; assert the version/log stay in lock-step with the catalog
    - _Requirements: 3.1, 3.4, 3.5_

- [x] 3. CatalogChange model and the changes-since query
  - [x] 3.1 Implement `CatalogChange` and `changes_since(cursor, page)`
    - Create `app/models/catalog_change.rb`; query rows with `version > cursor` ordered by `version` ascending, paginated via `pagy`; hydrate each upsert from its live `Song`/`Album`/`Artist` row (metadata + associations, Req 3.4) and pass deletions through by id+type (Req 3.5); return the library's current `catalog_version` to adopt; return an empty change set when `cursor >= catalog_version` (Req 3.6); return `full_sync_required: true` with no partial set when `cursor` is below the retained log floor (Req 3.7)
    - _Requirements: 3.2, 3.4, 3.5, 3.6, 3.7_

  - [x] 3.2 Write property test for changes-since delta correctness
    - `# Feature: remote-library-mirror-sync, Property 2: Changes-since returns exactly the post-cursor changes in order, and is empty at or beyond the current version`
    - Generate random change logs and cursors (including `>=` current version and below the retention floor); assert exactly the post-cursor changes are returned in non-decreasing version order, upserts carry id/type/metadata/associations, deletions carry id/type, the set is empty at/beyond the current version, and full-sync-required is signalled below the floor
    - **Validates: Requirements 3.2, 3.4, 3.5, 3.6, 3.7** (Property 2), min 100 iterations
    - _Requirements: 3.2, 3.4, 3.5, 3.6, 3.7_

- [x] 4. Changes_Since_API federation endpoint
  - [x] 4.1 Implement `Federation::ChangesController` and its route
    - Create `app/controllers/federation/changes_controller.rb < Federation::BaseController`; reuse `authorize_federation!(params[:library_id])` (grant digest match + `usable?` + library reference) before serving; render `{ catalog_version, full_sync_required, changes: [...] }` reusing the existing jbuilder upsert shapes so the mirror receives the same field set local browsing produces; add `GET /federation/libraries/:id/changes`
    - _Requirements: 3.2, 3.3, 3.6, 3.7_

  - [x] 4.2 Write property test for changes-since authorization
    - `# Feature: remote-library-mirror-sync, Property 3: Changes-since requires an authorized, active, non-revoked, non-expired grant referencing the library`
    - Generate a presented token plus Access_Grant sets in arbitrary states; assert Catalog_Changes are returned iff the token matches exactly one grant that is active, unexpired, and references the requested library, and that every other case rejects with an authorization error and returns no changes
    - **Validates: Requirements 3.3, 9.4** (Property 3), min 100 iterations
    - _Requirements: 3.3, 9.4_

  - [x] 4.3 Write integration test for the Changes_Since_API round trip
    - Against a stubbed hosting server (`WebMock`): verify the paged change-response shape, the empty-set-at-current-version case, and a `403` rejection for an unauthorized/expired/wrong-library grant
    - Integration/smoke test (NOT property-based) — cross-server network path
    - _Requirements: 3.2, 3.3, 3.6_

- [x] 5. Phase 1 checkpoint
  - Run the full test suite; ensure the existing 843 tests still pass alongside the new hosting-side tests. Ask the user if questions arise.

---

## Phase 2 — Redeeming-side mirror schema and sync engine
**Requirements: 1, 2, 4, 5, 8, 10. Properties: 4, 5, 6, 7, 8, 9, 10.**
Delivers a browsable, self-reconciling Catalog_Mirror driven purely by the pull backbone.

- [x] 6. Redeeming-side mirror schema and conditional validations
  - [x] 6.1 Add `remote_*_id` columns and partial unique indexes to content tables
    - Migration (additive): add nullable `remote_song_id` to `songs`, `remote_album_id` to `albums`, `remote_artist_id` to `artists`
    - Add partial unique indexes on `(library_id, remote_song_id)`, `(library_id, remote_album_id)`, `(library_id, remote_artist_id)`, each `WHERE remote_*_id IS NOT NULL`, to enforce the `(Library_Connection, hosting-side id)` identity and make upserts idempotent
    - _Requirements: 2.2, 7.1, 8.2_

  - [x] 6.2 Add sync columns to `library_connections`
    - Migration (additive): `sync_cursor` integer default 0, `last_synced_at` datetime null, `sync_state` string default `fresh` (`fresh｜stale｜unavailable`, distinct from the existing lifecycle `status`), `nudge_token` string null with a unique index
    - _Requirements: 4.3, 4.6, 9.1, 10.1_

  - [x] 6.3 Relax `Song` file-column presence validations to local libraries only
    - Change the `Song` presence validations for `file_path`, `file_path_hash`, and `md5_hash` to `if: -> { library&.local? }`; add `remote_song_id`/`remote_album_id`/`remote_artist_id` accessors and the `sync_state` enum on the affected models
    - This is the main touch-point against existing model tests — it MUST NOT change validation for local-library songs
    - _Requirements: 1.2, 1.4_

  - [x] 6.4 Write unit tests for the conditional validation relaxation
    - Assert a `remote?`-library Song validates with no `file_path`/`file_path_hash`/`md5_hash`, while a `local?`-library Song still requires all three (existing behavior preserved)
    - _Requirements: 1.2, 1.4_

- [x] 7. Federation::Client changes-since call
  - [x] 7.1 Add `Federation::Client#changes_since(library_id, cursor, page)`
    - Add the method to the existing client reusing `CONTENT_TIMEOUT` and the existing domain errors; `GET /federation/libraries/:id/changes?cursor=&page=` and parse JSON; raise `Unauthorized` on `401/403` (the teardown signal), `Unreachable`/`Timeout` on transport failure (the stale signal)
    - _Requirements: 4.2, 10.5_

  - [x] 7.2 Write integration test for the changes-since timeout budget
    - Assert `changes_since` applies the 10s `CONTENT_TIMEOUT` and maps `403 → Unauthorized` and transport failure → `Unreachable`/`Timeout`
    - Integration/smoke test (NOT property-based) — network path / timeout budget
    - _Requirements: 10.5_

- [x] 8. Catalog_Sync pure apply engine
  - [x] 8.1 Implement `CatalogSync.apply(connection, changes)`
    - Create `app/models/catalog_sync.rb`; for each upsert `create_or_find_by!` the Mirrored_Artist and Mirrored_Album in the remote Library keyed on `(library_id, remote_artist_id)` / `(library_id, remote_album_id)`, then upsert the Mirrored_Song keyed on `(library_id, remote_song_id)`, wiring `album`/`artist` associations to the mirrored rows carrying the matching hosting-side ids; for each deletion remove the Mirrored_Song by `(library_id, remote_song_id)` then drop an orphaned Mirrored_Album/Mirrored_Artist iff no mirrored song remains (reuse the `Media.clean_up` orphan semantics scoped to the remote Library); tolerate per-item deletion failure, leaving the item for a later sync
    - _Requirements: 1.2, 1.3, 2.1, 2.3, 2.4, 2.5, 5.1, 5.2, 5.4, 8.2_

  - [x] 8.2 Write property test for idempotent apply
    - `# Feature: remote-library-mirror-sync, Property 5: Applying the same change set is idempotent`
    - Generate a Catalog_Mirror and a set of Catalog_Changes; assert applying the set more than once yields a mirror identical to applying it exactly once
    - **Validates: Requirements 8.2, 2.2** (Property 5), min 100 iterations
    - _Requirements: 8.2, 2.2_

  - [x] 8.3 Write property test for deletion propagation and orphan cleanup
    - `# Feature: remote-library-mirror-sync, Property 7: Deletions propagate and orphaned albums/artists are cleaned up exactly when unreferenced`
    - Generate a mirror and deletion changes (including orphan-producing deletions); assert the item identified by (connection, hosting-side id) is removed and a Mirrored_Album/Mirrored_Artist is removed iff no Mirrored_Song remains associated with it in the same mirror
    - **Validates: Requirements 5.1, 5.2** (Property 7), min 100 iterations
    - _Requirements: 5.1, 5.2_

  - [x] 8.4 Write property test for association preservation and per-connection scoping
    - `# Feature: remote-library-mirror-sync, Property 8: Mirrored items preserve associations and stay scoped per connection`
    - Generate multi-connection catalogs that share hosting-side id values; assert each Mirrored_Song links the Mirrored_Album/Mirrored_Artist carrying the matching hosting id, every mirrored item is scoped to exactly one Remote_Library, and two connections sharing a hosting id never cross-attribute
    - **Validates: Requirements 1.2, 1.3, 1.5, 2.1, 2.2, 2.3, 2.4** (Property 8), min 100 iterations
    - _Requirements: 1.2, 1.3, 1.5, 2.1, 2.2, 2.3, 2.4_

  - [x] 8.5 Write property test for the metadata-only invariant
    - `# Feature: remote-library-mirror-sync, Property 9: The mirror stores no audio or artwork bytes`
    - Generate materialized Catalog_Mirrors; assert no Mirrored_Song stores audio byte content and no Mirrored_Album/Mirrored_Artist stores artwork byte content
    - **Validates: Requirements 1.4** (Property 9), min 100 iterations
    - _Requirements: 1.4_

- [x] 9. Full and incremental sync with transactional atomicity
  - [x] 9.1 Implement `CatalogSync.full_sync` and `CatalogSync.incremental_sync`
    - `full_sync`: fetch the host catalog via the existing `Federation::Client` browse calls (songs/albums/artists, paged), rebuild the mirror to exactly that set by hosting-side id (removing anything absent), adopt the current `catalog_version`, set `sync_state: fresh`, record `last_synced_at`; `incremental_sync`: call `changes_since(sync_cursor)`, apply the delta, then advance the cursor to the returned `catalog_version`, falling back to `full_sync` on `full_sync_required`; wrap each sync's apply **and** its cursor advance in a single `ActiveRecord::Base.transaction`; on `Unreachable`/`Timeout` retain the last-known mirror and cursor unchanged and set `sync_state: stale`, continuing to serve and surfacing staleness
    - _Requirements: 1.1, 1.5, 1.6, 4.2, 4.3, 4.4, 4.6, 5.3, 8.1, 8.4, 10.1, 10.2, 10.3, 10.4_

  - [x] 9.2 Write property test for successful-sync convergence
    - `# Feature: remote-library-mirror-sync, Property 4: A successful sync converges the mirror to the host catalog at the adopted version`
    - Generate a host Catalog and an arbitrary starting mirror; assert after a successful sync the mirror equals the Catalog by hosting-side id with every association preserved, no absent item remaining and no extra item, the Sync_Cursor equals the adopted Catalog_Version, Sync_State is `fresh`, and Last_Synced_At is recorded
    - **Validates: Requirements 1.6, 2.5, 4.3, 4.6, 5.3, 8.1, 8.4, 10.4** (Property 4), min 100 iterations
    - _Requirements: 1.6, 2.5, 4.3, 4.6, 5.3, 8.1, 8.4, 10.4_

  - [x] 9.3 Write property test for full/incremental convergence
    - `# Feature: remote-library-mirror-sync, Property 6: Full and incremental syncs to the same version converge to identical mirrors`
    - Generate a target Catalog reached by a Full_Sync versus a series of Incremental_Syncs that each advance to the same Catalog_Version; assert the resulting Catalog_Mirrors are identical
    - **Validates: Requirements 8.3, 4.4** (Property 6), min 100 iterations
    - _Requirements: 8.3, 4.4_

  - [x] 9.4 Write property test for failed-sync retention and staleness
    - `# Feature: remote-library-mirror-sync, Property 10: A failed sync retains the mirror and cursor and marks it stale`
    - Generate syncs that fail via unreachable/timeout or via mid-apply failure injection; assert the mirror is left in its pre-sync state, the Sync_Cursor is unchanged, Sync_State is `stale`, and the mirror is never left partially updated with an advanced cursor
    - **Validates: Requirements 10.1, 10.3** (Property 10), min 100 iterations
    - _Requirements: 10.1, 10.3_

  - [x] 9.5 Write unit tests for stale serving and recovery branches
    - Assert a `stale` connection keeps serving its last-known Catalog_Mirror and surfaces staleness rather than presenting it as fresh (Req 10.2); assert a previously-failed sync that later succeeds sets Sync_State to `fresh` and brings the mirror to the host's current Catalog (Req 10.4)
    - _Requirements: 10.2, 10.4_

- [x] 10. Sync job, scheduler, first-connection full-sync, and local browsing
  - [x] 10.1 Implement `CatalogSyncJob` and the recurring Sync_Scheduler
    - Create `app/jobs/catalog_sync_job.rb` (`perform(library_connection_id, mode: :incremental)`); add a SolidQueue recurring task that every `Poll_Interval` enqueues an incremental `CatalogSyncJob` for each `LibraryConnection.active`; make `Poll_Interval` configurable via `BlackCandy.config`/`Setting` with a defined default (e.g. 15 minutes) applied when unset
    - _Requirements: 4.1, 4.5, 4.6_

  - [x] 10.2 Hook the first-connection Full_Sync into redemption
    - In `InviteManager#find_or_create_connection`, enqueue `CatalogSyncJob(connection.id, mode: :full)` only when a **new** connection is created, so the mirror is materialized on establishment; re-redemption that reuses an existing connection does not re-trigger a full sync
    - _Requirements: 1.1_

  - [x] 10.3 Write unit/integration tests for scheduler timing and sync wiring
    - Assert the recurring Sync_Scheduler enqueues exactly one incremental `CatalogSyncJob` per active connection at the configured Poll_Interval and applies the default when unset (Req 4.1, 4.5); assert an Incremental_Sync passes the recorded Sync_Cursor (Req 4.2) and takes the Full_Sync branch on `full_sync_required` (Req 4.4); assert redemption enqueues a Full_Sync only on new-connection creation (Req 1.1)
    - Integration/smoke test (NOT property-based) — scheduler timing & job wiring
    - _Requirements: 1.1, 4.1, 4.2, 4.4, 4.5_

  - [x] 10.4 Write test that browsing a Catalog_Mirror uses local queries only
    - Assert listing/searching a remote Library's mirrored content returns the mirrored rows via local queries and issues zero `Federation::Client` calls to satisfy the browse/search/list
    - Integration/smoke test (NOT property-based) — verifies the no-live-round-trip guarantee
    - _Requirements: 1.7_

- [x] 11. Phase 2 checkpoint
  - Run the full test suite; ensure the existing 843 tests plus the new mirror/sync tests pass and browsing a mirror issues zero Federation calls. Ask the user if questions arise.

---

## Phase 3 — Best-effort nudge
**Requirements: 6. Property: 15.**
Adds the fire-and-forget Catalog_Nudge as an optimization on top of Phase 2's converging pull backbone. Correctness never depends on nudge delivery.

- [x] 12. Nudge registration and hosting-side sender
  - [x] 12.1 Add nudge columns to `access_grants` and register the callback at redemption
    - Migration (additive): add `nudge_callback_url` string null and `nudge_token` string null to `access_grants`
    - Have the redeemer generate a random `nudge_token` and its `nudge_callback_url` (its base URL + `/nudges`) at redemption and pass them via `confirm_grant`; the host stores them on the Access_Grant; store the `nudge_token` on the redeemer's `LibraryConnection`
    - _Requirements: 6.1, 6.5_

  - [x] 12.2 Implement `CatalogNudgeJob` (fire-and-forget) on the host
    - Create `app/jobs/catalog_nudge_job.rb`; for a changed local library, POST `{ nudge_token }` to each `AccessGrant.active` that has a `nudge_callback_url`, using a short timeout and **no** indefinite retry; a NAT-unreachable redeemer is a non-fatal miss that leaves the Catalog and Access_Grant unchanged; enqueue the job from the `CatalogVersioning` bump hook after the change commits
    - _Requirements: 6.1, 6.3_

  - [x] 12.3 Write integration test for nudge delivery
    - Assert a catalog change enqueues nudges to registered callbacks and that an unreachable callback fails without a retry storm, leaving the Catalog and Access_Grant unchanged
    - Integration/smoke test (NOT property-based) — nudge network path
    - _Requirements: 6.1, 6.3_

- [x] 13. Redeeming-side Nudge_Endpoint
  - [x] 13.1 Implement `NudgesController` and its route
    - Create `app/controllers/nudges_controller.rb < ActionController::API` (skip session auth and CSRF like the federation endpoints); `POST /nudges { nudge_token }` looks up the `LibraryConnection` by `nudge_token`, enqueues an immediate incremental `CatalogSyncJob` when the connection is found and active, and always returns `204` so unknown/inactive tokens are ignored without disclosure; add the route
    - _Requirements: 6.2, 6.5_

  - [x] 13.2 Write property test for nudge-to-connection mapping
    - `# Feature: remote-library-mirror-sync, Property 15: A catalog nudge schedules a sync exactly when it maps to a held connection`
    - Generate arbitrary nudge tokens against a set of held connections; assert an immediate Incremental_Sync is scheduled iff the nudge maps to a Library_Connection the redeemer holds, a nudge for an unknown connection is ignored, and convergence through the next scheduled Incremental_Sync holds whether or not any nudge was received
    - **Validates: Requirements 6.2, 6.4, 6.5** (Property 15), min 100 iterations
    - _Requirements: 6.2, 6.4, 6.5_

- [x] 14. Phase 3 checkpoint
  - Run the full test suite; ensure the existing tests plus the new nudge tests pass. Ask the user if questions arise.

---

## Phase 4 — Live playback, artwork, teardown, and local-only guarantees
**Requirements: 7, 9, 11. Properties: 11, 12, 13, 14.**
Delivers listen-and-view over the byte-less mirror with correct source-selection, teardown, and preserved DAAP/RSP local-only serving.

- [x] 15. Live playback wiring
  - [x] 15.1 Return the stored `remote_song_id` from `RemoteStreamController`
    - Change `RemoteStreamController#remote_song_id` to return the stored `song.remote_song_id` instead of `song.id`, resolving the controller's standing ASSUMPTION; keep the connection load via `song.library.library_connection`, the 10s timeout, range forwarding, and `render_unavailable` unchanged; fail playback immediately with `503` and no stored-bytes fallback when the host is unavailable
    - _Requirements: 7.2, 7.3_

  - [x] 15.2 Write property test for remote classification and stream keying
    - `# Feature: remote-library-mirror-sync, Property 14: Mirrored songs classify as remote and resolve through the same-origin proxy keyed on the hosting id`
    - Generate Mirrored_Songs across connection states; assert Path_Resolver classifies Stream_Source as `remote`, produces a same-origin remote-stream proxy path when the connection is active, and that the audio fetch is keyed on the pairing of the Library_Connection and the stored Remote_Song_Id
    - **Validates: Requirements 7.1, 7.5** (Property 14), min 100 iterations
    - _Requirements: 7.1, 7.5_

  - [x] 15.3 Write integration test for the live audio proxy
    - Assert `RemoteStreamController` proxies via the stored `remote_song_id`, forwards range headers, and returns `503` with no fallback when the host is unavailable
    - Integration/smoke test (NOT property-based) — live audio network path
    - _Requirements: 7.2, 7.3_

- [x] 16. Live artwork wiring
  - [x] 16.1 Implement `RemoteAssetController` and its route
    - Create `app/controllers/remote_asset_controller.rb` mirroring `RemoteStreamController`; load the Mirrored_Album/Mirrored_Artist, read its `remote_album_id`/`remote_artist_id`, and proxy the bytes live via `Federation::Client#asset(remote_library_id, type, remote_id, variant:)`; store no artwork bytes; map the `/asset/remote/:type/:id` path already emitted by `Path_Resolver#resolve_asset`; add the route
    - _Requirements: 7.4, 1.4_

  - [x] 16.2 Write integration test for the live artwork proxy
    - Assert `RemoteAssetController` proxies artwork via the stored `remote_album_id`/`remote_artist_id`, surfaces unavailability when the host is down, and stores no bytes
    - Integration/smoke test (NOT property-based) — live artwork network path
    - _Requirements: 7.4_

- [x] 17. Shared availability predicate and browse-scope exclusion
  - [x] 17.1 Extract the `RemoteAvailability` predicate and share it
    - Create `app/models/remote_availability.rb` with `available?(song)` (local songs always available; a Mirrored_Song available iff its Remote_Library's `library_connection` is present and active); call it from both `Path_Resolver#remote_connection_resolvable?` and `SourcePreference.select`'s availability filter so the two can never disagree
    - _Requirements: 11.2, 11.3_

  - [x] 17.2 Exclude non-active remote connections from browse/search/list
    - Update the authorized-libraries helper so a remote Library is browsable only while `library.library_connection&.active?`; stop serving a mirror for browsing, searching, and listing once its connection status is `revoked` or `unavailable`
    - _Requirements: 9.2, 11.3_

  - [x] 17.3 Write property test for availability consistency
    - `# Feature: remote-library-mirror-sync, Property 12: Mirrored-song availability is consistent across selection and resolution`
    - Generate Mirrored_Songs across connection states (`active｜revoked｜unavailable｜stale`); assert a Mirrored_Song is available for Source_Preference selection iff it is resolvable by Path_Resolver, and is unavailable for both together while the connection is not active
    - **Validates: Requirements 11.2, 11.3** (Property 12), min 100 iterations
    - _Requirements: 11.2, 11.3_

- [x] 18. Mirror teardown
  - [x] 18.1 Implement teardown on auth-error, revocation/unavailability, and deletion
    - On a sync `Unauthorized` (403), remove the Catalog_Mirror or mark it unavailable and set `sync_state: unavailable` (Req 9.1, 9.4); when a Library_Connection's status becomes `revoked`/`unavailable`, stop serving its mirror (Req 9.2); on connection deletion, remove the mirror in full via the remote `Library`'s existing `destroy_scoped_content` (Req 9.3); leave every other connection's mirror unchanged because everything is `library_id`-scoped (Req 9.5)
    - _Requirements: 9.1, 9.2, 9.3, 9.4, 9.5_

  - [x] 18.2 Write property test for teardown locality
    - `# Feature: remote-library-mirror-sync, Property 11: Teardown removes or hides only the affected connection's mirror`
    - Generate multiple Library_Connections with mirrors; tear one down via each path (authorization error, status becoming revoked/unavailable, deletion); assert only that connection's mirror is removed or hidden and every other connection's mirror remains unchanged and still browsable
    - **Validates: Requirements 9.1, 9.2, 9.3, 9.5** (Property 11), min 100 iterations
    - _Requirements: 9.1, 9.2, 9.3, 9.5_

- [x] 19. Local-only serving guarantees and deduplication treatment
  - [x] 19.1 Treat mirrored songs as remote copies and confirm DAAP/RSP/own-Federation exclusion
    - Ensure `Deduplicator` and `Source_Preference` treat a Mirrored_Song as a remote copy available only while its Library_Connection is active (reusing `RemoteAvailability`); confirm the DAAP_Service, RSP_Service, and the current Server's own Federation API exclude all mirrored content by construction (`Library.local` scoping), adding explicit guards where the exclusion is not already enforced by scope
    - _Requirements: 11.1, 11.2, 11.4_

  - [x] 19.2 Write property test for local-only exclusion
    - `# Feature: remote-library-mirror-sync, Property 13: DAAP, RSP, and the server's own Federation API expose no mirrored content`
    - Generate library and authorization configurations; assert the content served over the DAAP_Service or RSP_Service is a subset of the current Server's Local_Library content and contains no Mirrored_Song/Mirrored_Album/Mirrored_Artist, and that the Server's own Federation API endpoints likewise expose no mirrored content
    - **Validates: Requirements 11.1, 11.4** (Property 13), min 100 iterations
    - _Requirements: 11.1, 11.4_

- [x] 20. Phase 4 checkpoint
  - Run the full test suite; ensure the existing 843 tests plus all new tests pass and the DAAP/RSP local-only rule is preserved. Ask the user if questions arise.

## Notes

- The project uses **Minitest + rantly**; every property test reuses the existing `check_property` harness (`test/support/property_helper.rb`) — no new generator or runner is created — runs a **minimum of 100 iterations**, and carries the tag `# Feature: remote-library-mirror-sync, Property {number}: {property_text}`.
- Each task references specific requirement clauses and, where applicable, the design correctness property it validates.
- The 15 correctness properties map one-to-one to property test tasks: P1→2.2, P2→3.2, P3→4.2, P4→9.2, P5→8.2, P6→9.3, P7→8.3, P8→8.4, P9→8.5, P10→9.4, P11→18.2, P12→17.3, P13→19.2, P14→15.2, P15→13.2.
- Protocol/network paths the design marks NOT property-testable (Changes_Since_API round trip, nudge delivery, live audio proxy, live artwork proxy, scheduler timing, timeout budget) are covered by the distinct integration/smoke test tasks 4.3, 7.2, 10.3, 10.4, 12.3, 15.3, and 16.2.
- All schema work is additive and backward-compatible; the `Song` file-column validation relaxation (task 6.3) is conditioned on `local?` libraries so existing local content and its tests are unaffected.
- Phases are independently shippable; each ends with a checkpoint that runs the full suite to protect the existing 843 passing tests and the DAAP/RSP local-only rule.

## Task Dependency Graph

```json
{
  "waves": [
    { "id": 0, "tasks": ["1.1"] },
    { "id": 1, "tasks": ["3.1", "6.1", "6.2"] },
    { "id": 2, "tasks": ["2.1", "3.2", "4.1", "6.3", "7.1"] },
    { "id": 3, "tasks": ["2.2", "2.3", "4.2", "4.3", "6.4", "7.2", "8.1", "17.1"] },
    { "id": 4, "tasks": ["2.4", "8.2", "8.3", "8.4", "8.5", "9.1", "17.2", "17.3", "19.1"] },
    { "id": 5, "tasks": ["9.2", "9.3", "9.4", "9.5", "10.1", "10.2", "15.1", "16.1", "18.1", "19.2"] },
    { "id": 6, "tasks": ["10.3", "10.4", "12.1", "15.2", "15.3", "16.2", "18.2"] },
    { "id": 7, "tasks": ["12.2", "13.1"] },
    { "id": 8, "tasks": ["12.3", "13.2"] }
  ]
}
```
