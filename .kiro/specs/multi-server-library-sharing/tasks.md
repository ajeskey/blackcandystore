# Implementation Plan: Multi-Server Library Sharing

## Overview

This plan implements multi-library and cross-server library sharing on top of the existing Black Candy Rails app. Work is organized under the five phases of the design's Phased Delivery Plan; each phase is independently shippable and leaves the system working.

Within each phase, tasks are sequenced migrations → models → services → controllers → player/API integration so each step builds on the last with no orphaned code. Every task grounds itself in the existing codebase (`Song`/`Album`/`Artist`/`Playlist`/`User`/`Setting` models, the `Media`/`MediaSyncJob`/`MediaSyncAllJob` scan pipeline, `song_helper.rb`'s `song_json_builder`, `Stream`, `MediaFile`, controllers under `app/controllers`, and `db/migrate`).

Testing follows the design's dual approach:
- **Property-based tests** cover the 23 correctness properties. The project uses **Minitest**; a property-testing generator library is added in task 1.1. Each property test runs a **minimum of 100 iterations** and is tagged with a comment in the exact format `# Feature: multi-server-library-sharing, Property {number}: {property_text}`.
- **Integration / smoke tests** (using `WebMock` and stubbed sidecars/servers) cover the protocol and network paths that the design explicitly marks NOT property-testable: cross-server federation, mDNS device discovery, the server-driven playback audio path, client casting device path, and DAAP/RSP serving.

High-risk protocol work (AirPlay/Chromecast in Phase 4, DAAP/RSP in Phase 5) is isolated behind a sidecar/service boundary; the Rails-side pure logic (session state machines, content selection) is property-tested while the wire protocols are covered only by integration/smoke tests and flagged as depending on external components.

---

## Phase 1 — Multi-library foundation, scanning, scoped browsing
**Requirements: 1, 2, 3. Properties: 1, 2, 3, 4, 5.**
Delivers a working multi-library single server. No cross-server behavior yet.

## Tasks

- [x] 1. Test tooling and property-test harness setup
  - [x] 1.1 Add and wire up the property-based testing harness
    - Add a property-testing generator gem (e.g. `rantly`) to the `:test` group in `Gemfile` and `bundle install`
    - Create `test/support/property_helper.rb` with a `check_property(iterations: 100, &block)` helper that runs a minimum of 100 iterations and shrinks/records the failing example
    - Require the helper from `test/test_helper.rb`; document the required tag format `# Feature: multi-server-library-sharing, Property {number}: {property_text}`
    - _Requirements: supports all property tests; Testing Strategy_

- [x] 2. Library model, schema, and library-scoping migrations
  - [x] 2.1 Create the `libraries` table and add `library_id` foreign keys
    - Generate migration creating `libraries` (`name`, `kind`, `media_path`, `owner_id` fk users, `scan_state` default `idle`, `is_default` default false, `library_connection_id` nullable)
    - Add nullable `library_id` fk to `songs`, `albums`, `artists` (made not-null after the Phase 1 backfill)
    - Add a case-insensitive unique index on `libraries.name`
    - _Requirements: 1.1, 1.2, 1.7, 1.8, 2.2_

  - [x] 2.2 Relax global uniqueness indexes to be library-scoped
    - Migration: drop `index_songs_on_md5_hash`, add composite unique index on `(library_id, md5_hash)`
    - Drop `index_albums_on_artist_id_and_name` / `index_artists_on_name`, re-add scoped to `library_id`
    - _Requirements: 2.3, 12.5_

  - [x] 2.3 Implement the `Library` model with validations and content associations
    - Create `app/models/library.rb`: `belongs_to :owner`, `has_many :songs/:albums/:artists`, `scopes :local`, `enum scan_state`
    - Validate `name` trimmed length 1–255 and case-insensitive uniqueness (Req 1.2, 1.9, 1.10)
    - Validate `media_path` exists and is readable for `local` libraries, mirroring `Setting#media_path_exist`; add a not-verifiable branch (Req 1.3, 1.4, 1.11)
    - Add `library_id` associations to `Song`, `Album`, `Artist` models
    - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5, 1.9, 1.10, 1.11_

  - [x] 2.4 Write property test for library name acceptance
    - `# Feature: multi-server-library-sharing, Property 1: Library name acceptance is valid-and-unique`
    - Generate candidate names (incl. whitespace-only, 256-char, case-variant duplicates); assert accept iff trimmed length 1–255 and not a case-insensitive duplicate, and rejects leave existing libraries unchanged
    - **Validates: Requirements 1.2, 1.9, 1.10** (Property 1), min 100 iterations
    - _Requirements: 1.2, 1.9, 1.10_

  - [x] 2.5 Write unit tests for media-path validation messages
    - Test missing, unreadable, and unverifiable path branches return the specific validation errors and leave existing libraries unchanged
    - _Requirements: 1.3, 1.4, 1.11_

- [x] 3. Default_Library backfill migration
  - [x] 3.1 Implement the Default_Library data migration
    - Data migration: create one `Library` (`kind: local`, `is_default: true`, name `"Default Library"`, `media_path: Setting.media_path`, `owner_id:` first admin)
    - `UPDATE songs/albums/artists SET library_id = <default>` for all null rows, then add not-null constraint on `library_id`
    - Leave existing ActiveStorage `cover_image` attachments and stream paths untouched
    - _Requirements: 1.7, 8.8, 9.5_

  - [x] 3.2 Write migration test for the Default_Library backfill
    - Load a pre-feature schema fixture (songs/albums/artists with null `library_id`, existing cover images), run the migration
    - Assert exactly one `is_default` library, all content associated to it, unchanged cover-image URLs, unchanged stream URLs
    - Integration-style migration test (NOT property-based)
    - _Requirements: 1.7, 8.8, 9.5_

- [x] 4. Per-library scanning (generalize the Media pipeline)
  - [x] 4.1 Parameterize `Media` content creation by `library_id`
    - Update `Media.attach` / `Media.sync` / `Media.clean_up` so artist/album/song `create_or_find_by!` lookups are scoped to `library_id` (the `(library_id, md5_hash)` key from 2.2)
    - Scope clean-up so an album/artist is removed iff no song remains for it within scope
    - _Requirements: 2.1, 2.3, 2.4, 2.5_

  - [x] 4.2 Implement `LibraryScanJob` with per-library scan state
    - Create `app/jobs/library_scan_job.rb` subclassing `MediaSyncJob`; `perform(library_id)` scans `library.media_path` via `MediaFile.file_paths` and stamps `library_id` on created content
    - Set `scan_state: :syncing` at start, `:idle` on success, `:failed` in an `ensure`/at-exit path if terminated mid-scan; replace the global `Media.syncing?` cache flag with the per-library column plus a broadcast
    - Update `MediaSyncingController` and `LibrariesController` to trigger and report per-library scans
    - _Requirements: 2.1, 2.6, 2.7, 2.8_

  - [x] 4.3 Write property test for single-library association
    - `# Feature: multi-server-library-sharing, Property 2: Every song belongs to exactly one library`
    - Generate scanned content sets across multiple libraries; assert each `Song` is associated with exactly one `Library`
    - **Validates: Requirements 2.2** (Property 2), min 100 iterations
    - _Requirements: 2.2_

  - [x] 4.4 Write property test for duplicate-file scanning across libraries
    - `# Feature: multi-server-library-sharing, Property 3: Same file under two libraries yields two songs`
    - Generate the same media file present under two distinct local libraries' paths; assert two separate songs, one per library
    - **Validates: Requirements 2.3** (Property 3), min 100 iterations
    - _Requirements: 2.3_

  - [x] 4.5 Implement library deletion cascade
    - Add `Library` deletion that removes its songs and cascades album/artist cleanup scoped to the library (reusing `Media.clean_up` semantics), and deletes the library's `Access_Grant`s (grants table lands in Phase 2; guard until then)
    - _Requirements: 1.6, 2.4, 2.5_

  - [x] 4.6 Write property test for deletion cascade
    - `# Feature: multi-server-library-sharing, Property 4: Library deletion cascade preserves exactly the still-referenced albums and artists`
    - Generate datasets of songs/albums/artists across libraries; delete one library and assert its songs are removed and an album/artist survives iff a song still references it
    - **Validates: Requirements 2.4, 2.5** (Property 4), min 100 iterations
    - _Requirements: 2.4, 2.5_

- [x] 5. Active library selection and scoped browsing
  - [x] 5.1 Add persisted Active_Library selection to `User`
    - Add `active_library_id` to `users` (migration) and accessor on `User`; persist across sessions
    - Default to the single accessible library when the user has exactly one and none recorded
    - _Requirements: 3.1, 3.5_

  - [x] 5.2 Implement the `Library_Access_Controller` authorization concern
    - Create `app/controllers/concerns/library_access.rb` with `authorized_libraries(user)` (owned local + active remote connections; connections land in Phase 2, guard) and `authorize_library!(user, library)` raising `BlackCandy::Forbidden`
    - Add `authorize_active_library` handling: reject unauthorized selection, leave current Active_Library unchanged, and log the rejected attempt
    - _Requirements: 3.3, 3.4, 3.6, 3.9_

  - [x] 5.3 Scope browse/search/list controllers to the active library
    - Add a shared scope helper restricting `Song`/`Album`/`Artist` queries to `Current.user.active_library`; apply it in `albums_controller`, `artists_controller`, `songs` controllers, `search/*` controllers, and `libraries_controller#show`
    - Return empty results when the user has access to zero libraries
    - _Requirements: 3.2, 3.7_

  - [x] 5.4 Implement library list + active-content endpoint
    - Add controller action returning every owned local library plus active remote connections, including the current Active_Library's content alongside the list
    - _Requirements: 3.4, 3.8_

  - [x] 5.5 Write property test for active-library scoping
    - `# Feature: multi-server-library-sharing, Property 5: Browsing results are scoped to the active library`
    - Generate multi-library datasets and a user with an Active_Library; assert browse/search/list results are a subset of the active library and disjoint from every other library
    - **Validates: Requirements 3.2, 3.7** (Property 5), min 100 iterations
    - _Requirements: 3.2, 3.7_

  - [x] 5.6 Write unit tests for selection edge cases
    - Test single-library default selection (3.5), zero-library empty results (3.7), rejected unauthorized selection leaves Active_Library unchanged and is logged (3.6, 3.9)
    - _Requirements: 3.5, 3.6, 3.7, 3.9_

- [x] 6. Libraries management (CRUD) controller and routes
  - [x] 6.1 Implement admin library management endpoints
    - Add create/rename/delete actions (owner-only via `require_admin`) wiring to the `Library` model and deletion cascade; add routes
    - Reject non-owner create/modify with an authorization error
    - _Requirements: 1.1, 1.5, 1.6, 1.8_

  - [x] 6.2 Write controller tests for library management authorization
    - Test non-owner rejection (1.8), rename preserves content associations (1.5), delete removes associations (1.6)
    - _Requirements: 1.5, 1.6, 1.8_

- [x] 7. Phase 1 checkpoint
  - Ensure all tests pass, ask the user if questions arise.

---

## Phase 2 — Invite codes, cross-server access, remote streaming, resolved paths
**Requirements: 4, 5, 6, 7, 8, 9, 10. Properties: 6, 7, 8, 9, 10, 11, 12, 13, 14, 15.**
Delivers full cross-server browse/stream/share with revocation.

- [x] 8. Sharing schema: access grants and library connections
  - [x] 8.1 Create `access_grants` and `library_connections` migrations
    - `access_grants` (hosting side): `library_id` fk, `token_digest`, `redeemer_user_id` nullable, `redeemer_identity` nullable, `status` default `active`, `expires_at`, `redeemed_at` nullable
    - `library_connections` (redeeming side): `server_base_url`, `remote_library_id`, encrypted `grant_token`, `user_id` fk, `status` default `active`; unique index on `(user_id, server_base_url, remote_library_id)`
    - _Requirements: 4.1, 4.4, 5.1, 5.9, 6.2, 7.2_

  - [x] 8.2 Implement `AccessGrant` and `LibraryConnection` models
    - `AccessGrant`: `belongs_to :library`, status enum, token stored hashed with constant-time compare helper; scopes `active`/`revoked`
    - `LibraryConnection`: `belongs_to :user`, status enum (`active｜revoked｜unavailable`), encrypted `grant_token`
    - Wire the Phase 1 deletion cascade (task 4.5) to delete a library's grants (Req 1.6)
    - _Requirements: 1.6, 4.1, 5.1, 6.2, 7.2_

- [x] 9. Invite_Manager pure encode/decode + generation
  - [x] 9.1 Implement invite encode/decode
    - Create `app/models/invite_manager.rb`: `encode(server_base_url:, secret_token:)` → Base64URL JSON, `decode(invite_code)` reversing it and raising `InviteManager::Malformed` on bad input
    - _Requirements: 4.3, 4.7, 5.3_

  - [x] 9.2 Write property test for invite round-trip
    - `# Feature: multi-server-library-sharing, Property 6: Invite code round-trips`
    - Generate random base URLs + secret tokens; assert `decode(encode(...))` yields the same values
    - **Validates: Requirements 4.7** (Property 6), min 100 iterations
    - _Requirements: 4.7_

  - [x] 9.3 Write property test for malformed-code rejection
    - `# Feature: multi-server-library-sharing, Property 7: Malformed invite codes are rejected without side effects`
    - Generate non-ASCII/empty/garbage strings; assert redemption rejects as malformed and leaves existing access unchanged
    - **Validates: Requirements 5.3** (Property 7), min 100 iterations
    - _Requirements: 5.3_

  - [x] 9.4 Implement invite generation with validation
    - `InviteManager.generate(library:, owner:, expires_in: 7.days)`: validate ownership (4.6), library existence (4.9), `SecureRandom.hex(16)` token (4.2), expiration range 1 minute–365 days (4.5, 4.8); create `AccessGrant` and return the encoded `Invite_Code`
    - _Requirements: 4.1, 4.2, 4.3, 4.4, 4.5, 4.6, 4.8, 4.9_

  - [x] 9.5 Write property test for expiration-duration validation
    - `# Feature: multi-server-library-sharing, Property 8: Invite expiration duration validation`
    - Generate durations across/around the 1-minute–365-day bounds; assert create iff in range with `expires_at = created_at + duration`, else reject and create no grant
    - **Validates: Requirements 4.5, 4.8** (Property 8), min 100 iterations
    - _Requirements: 4.5, 4.8_

- [x] 10. Federation API and client (protocol/network — integration-tested)
  - [x] 10.1 Implement `Federation::Client` with timeouts
    - Create `app/models/federation/client.rb` (using `httparty`) centralizing Bearer-token calls, `open_timeout`/`read_timeout`, and error translation to domain exceptions; endpoints: grant confirm, ping, browse, stream, asset
    - _Requirements: 5.2, 5.7, 6.2, 6.3_

  - [x] 10.2 Implement hosting-side federation controllers
    - Create `app/controllers/federation/*`: `grants#confirm`, `libraries#{songs,albums,artists}`, `songs#stream`, `assets#show`, `ping`; each authorizes via `authorize_grant!`
    - Serve only local, authorized content
    - _Requirements: 5.2, 6.1, 6.2, 6.4, 9.4, 9.6_

  - [x] 10.3 Write integration tests for the federation protocol path
    - Using `WebMock`/a stubbed hosting server: verify grant confirmation, remote browse/stream/asset fetch, 30s redemption timeout (5.7), 10s content timeout (6.3), and revocation-mid-use surfacing (6.7)
    - Integration/smoke tests (NOT property-based) — cross-server network path
    - _Requirements: 5.2, 5.7, 6.2, 6.3, 6.4, 6.7, 9.6_

- [x] 11. Redemption and access authorization
  - [x] 11.1 Implement `InviteManager.redeem`
    - Local-library codes: grant access and record redemption (5.1); idempotent re-redemption of a non-revoked grant reports success with no duplicate grant/connection (5.6, 5.9)
    - Cross-server codes: confirm with issuing server within 30s then create a single `LibraryConnection` (5.2, 5.9); reject on unreachable/timeout (5.7), revoked/invalid (5.5, 5.8), expired first-time (5.4)
    - _Requirements: 5.1, 5.2, 5.4, 5.5, 5.6, 5.7, 5.8, 5.9_

  - [x] 11.2 Write property test for idempotent redemption
    - `# Feature: multi-server-library-sharing, Property 9: Redemption is idempotent`
    - Generate already-redeemed non-revoked codes; assert re-redeem reports success, state unchanged, no duplicate grant/connection
    - **Validates: Requirements 5.6, 5.9** (Property 9), min 100 iterations
    - _Requirements: 5.6, 5.9_

  - [x] 11.3 Implement `authorize_grant!` in the Library_Access_Controller
    - Federation authorization: hash presented token, look up matching `AccessGrant`; reject on no-match, revoked, expired, or wrong-library; perform defense-in-depth checks (match alone never sufficient); return explicit authorization error body, never a silent drop
    - _Requirements: 6.4, 6.5, 6.6, 6.8, 7.3, 7.4_

  - [x] 11.4 Write property test for federation authorization
    - `# Feature: multi-server-library-sharing, Property 10: Federation content requires an authorized, active, non-revoked grant`
    - Generate token + grant sets in mixed states; assert content returned iff exactly one matching grant is active, unexpired, and references the requested library; otherwise authorization error and no content
    - **Validates: Requirements 6.5, 6.6, 6.8, 7.3, 7.4** (Property 10), min 100 iterations
    - _Requirements: 6.5, 6.6, 6.8, 7.3, 7.4_

- [x] 12. Access control and revocation
  - [x] 12.1 Implement access list and revocation
    - Owner-only endpoint listing a local library's grants with redemption status + expiration (empty list when none) (7.1)
    - `InviteManager.revoke(access_grant:, owner:)`: verify ownership, mark grant revoked, idempotent on already-revoked, not-found error for missing grant, preserve other grants unchanged
    - _Requirements: 7.1, 7.2, 7.5, 7.6, 7.7, 7.8, 7.9_

  - [x] 12.2 Write property test for revocation locality and idempotency
    - `# Feature: multi-server-library-sharing, Property 11: Revocation is local and idempotent`
    - Generate grant sets; revoke one and assert only that grant changes to revoked; re-revoking an already-revoked grant leaves it revoked and reports success
    - **Validates: Requirements 7.6, 7.7** (Property 11), min 100 iterations
    - _Requirements: 7.6, 7.7_

  - [x] 12.3 Write controller tests for access-list authorization
    - Test non-owner view/revoke rejection (7.5) and not-found revocation error (7.8)
    - _Requirements: 7.5, 7.8_

- [x] 13. Invite/redemption/access controllers and routes
  - [x] 13.1 Add invites, redemptions, and access-grants controllers
    - Owner-only invites#create; redemptions#create; access grants index/destroy; wire routes and surface domain errors via `errors_controller`
    - _Requirements: 4.1, 4.6, 5.1, 5.3, 7.1, 7.2, 7.5_

- [x] 14. Path_Resolver: stream and asset resolution
  - [x] 14.1 Implement `PathResolver#resolve_stream`
    - Create `app/models/path_resolver.rb`: classify `stream_source` `local` (incl. Default_Library and undeterminable association) vs `remote`; local → existing `new_stream_url`/`new_transcoded_stream_url`, remote → same-origin proxy URL `/stream/remote/:song_id`
    - Unresolvable remote connection → empty `resolved_stream_path` + `available: false`, other attributes preserved
    - _Requirements: 8.1, 8.3, 8.4, 8.5, 8.8, 8.9, 8.10, 8.11_

  - [x] 14.2 Write property test for stream-source classification/resolution
    - `# Feature: multi-server-library-sharing, Property 12: Stream-source classification and resolution are consistent`
    - Generate songs across local/remote/default/unknown libraries; assert source classification and that successful resolution yields a non-empty path pointing at the correct server
    - **Validates: Requirements 8.1, 8.3, 8.4, 8.5, 8.8, 8.9, 8.10** (Property 12), min 100 iterations
    - _Requirements: 8.1, 8.3, 8.4, 8.5, 8.8, 8.9, 8.10_

  - [x] 14.3 Write property test for unresolvable remote content
    - `# Feature: multi-server-library-sharing, Property 13: Unresolvable remote content yields an empty path and preserves other attributes`
    - Generate remote songs/assets with unresolvable connections; assert empty path, unavailable flag, all other attributes unchanged
    - **Validates: Requirements 8.11, 9.8** (Property 13), min 100 iterations
    - _Requirements: 8.11, 9.8_

  - [x] 14.4 Implement `PathResolver#resolve_asset`
    - Classify `asset_source` from owning content's library kind; local → current-server path, remote → hosting asset endpoint via connection; existing cover images classified `local` with pre-existing URL; no cover image → empty path + absence indication; unresolvable remote → empty + unavailable, other attributes preserved
    - _Requirements: 9.1, 9.2, 9.3, 9.4, 9.5, 9.7, 9.8, 9.9_

  - [x] 14.5 Write property test for asset-source classification/resolution
    - `# Feature: multi-server-library-sharing, Property 14: Asset-source classification and resolution are consistent`
    - Generate albums/artists across local/remote with/without cover images; assert source classification, non-empty path when a cover exists and resolves, empty + absence when none
    - **Validates: Requirements 9.1, 9.2, 9.3, 9.4, 9.5, 9.7, 9.9** (Property 14), min 100 iterations
    - _Requirements: 9.1, 9.2, 9.3, 9.4, 9.5, 9.7, 9.9_

- [x] 15. Integrate resolution into player/API serialization
  - [x] 15.1 Extend `song_json_builder` and album/artist JSON with resolved paths
    - Update `app/helpers/song_helper.rb` `song_json_builder` to add `stream_source` + `resolved_stream_path` via `PathResolver` while keeping the existing `url` field working (backward compatible)
    - Extend album/artist JSON with `asset_source` + `resolved_asset_path`
    - _Requirements: 8.3, 8.10, 9.2, 9.9_

  - [x] 15.2 Implement the remote-stream proxy endpoint
    - Add `stream/remote#show` that maps `/stream/remote/:song_id` to the hosting federation stream endpoint via `Federation::Client`, keeping the grant credential server-side and enforcing the 10s timeout; add route
    - _Requirements: 6.2, 6.3, 8.5_

  - [x] 15.3 Write integration test for remote-stream proxy
    - With a stubbed hosting server, assert the proxy streams bytes, keeps credentials server-side, and surfaces unavailability on timeout
    - Integration test (NOT property-based) — network path
    - _Requirements: 6.2, 6.3_

- [x] 16. Cross-server playlist resolution
  - [x] 16.1 Implement independent per-song playlist resolution
    - Update playlist JSON serialization to resolve each song's `stream_source`/`resolved_stream_path` independently via `PathResolver`, preserving order and membership; set only unavailable songs' paths empty; never reject the whole playlist
    - _Requirements: 10.1, 10.2, 10.3, 10.4, 10.5, 10.6, 10.7, 10.8_

  - [x] 16.2 Write property test for playlist resolution
    - `# Feature: multi-server-library-sharing, Property 15: Playlist resolution preserves order and membership and resolves each song independently`
    - Generate playlists mixing local/remote/unavailable songs; assert order/membership preserved, independent resolution, only unavailable songs emptied, response never rejected
    - **Validates: Requirements 10.3, 10.4, 10.5, 10.6, 10.7, 10.8** (Property 15), min 100 iterations
    - _Requirements: 10.3, 10.4, 10.5, 10.6, 10.7, 10.8_

- [x] 17. Phase 2 checkpoint
  - Ensure all tests pass, ask the user if questions arise.

---

## Phase 3 — Deduplication and source preference
**Requirements: 11, 12. Properties: 16, 17, 18, 19 (Source_Preference half).**

- [x] 18. Dedup schema and fingerprinting
  - [x] 18.1 Create dedup tables and add per-user source preference
    - Migration: `content_fingerprints` (`song_id` fk, `md5_hash`, nullable `acoustic_fingerprint`, `normalized_key`), `duplicate_groups` (`id`, `logical_track_key`), add `songs.duplicate_group_id` nullable fk
    - Add per-user `source_preference` setting (default `prefer_own_server`) via the `has_setting` pattern
    - _Requirements: 11.1, 11.2, 11.10, 12.1, 12.3_

  - [x] 18.2 Implement `ContentFingerprint` computation
    - Create fingerprinting: `md5_hash` + normalized metadata (name|artist|album|duration); keep acoustic `fpcalc` fingerprint pluggable/optional (Medium-risk native dependency — feature-flag it)
    - _Requirements: 12.1_

- [x] 19. Deduplicator classification and grouping
  - [x] 19.1 Implement `Deduplicator.same_content?` and `.group`
    - `same_content?` reflexive/symmetric equivalence: identical `md5_hash` or identical `Content_Fingerprint` → same content; implement `group(songs)` into `Duplicate_Group`s
    - Group albums/artists across libraries by matching normalized metadata (Req 12.5)
    - _Requirements: 12.1, 12.2, 12.3, 12.4, 12.5, 12.8, 12.9, 12.10_

  - [x] 19.2 Write property test for same-content reflexivity/symmetry
    - `# Feature: multi-server-library-sharing, Property 16: Same-content classification is reflexive and symmetric`
    - Generate songs incl. identical `md5_hash`/fingerprint pairs; assert reflexivity, symmetry, and that identical hash/fingerprint → same content
    - **Validates: Requirements 12.1, 12.2, 12.8, 12.9** (Property 16), min 100 iterations
    - _Requirements: 12.1, 12.2, 12.8, 12.9_

  - [x] 19.3 Write property test for grouping by fingerprint
    - `# Feature: multi-server-library-sharing, Property 17: Identical fingerprints are grouped together, distinct ones apart`
    - Generate song sets; assert identical-fingerprint pairs land in the same group and non-matching pairs in different groups
    - **Validates: Requirements 12.3, 12.4, 12.10** (Property 17), min 100 iterations
    - _Requirements: 12.3, 12.4, 12.10_

- [x] 20. Source preference selection
  - [x] 20.1 Implement `SourcePreference.select` and per-user setting validation
    - Deterministic ordering: `prefer_own_server` → own local copy else highest quality; `prefer_highest_quality` → lossless, then bit depth, then bitrate; ties → own library then lowest library id; no available copy → select none + mark unavailable
    - Validate submitted preference values (persist iff `prefer_own_server`/`prefer_highest_quality`, else reject unchanged)
    - _Requirements: 11.3, 11.4, 11.5, 11.6, 11.7, 11.8, 11.9, 11.10, 12.6, 12.7, 12.11_

  - [x] 20.2 Write property test for deterministic source selection
    - `# Feature: multi-server-library-sharing, Property 18: Source preference selects exactly one copy deterministically`
    - Generate duplicate groups with varying quality/availability and both preferences (incl. zero-source groups); assert exactly-one deterministic selection per rules, none + unavailable when empty
    - **Validates: Requirements 11.4, 11.5, 11.6, 11.7, 11.8, 11.9, 12.6, 12.7, 12.11** (Property 18), min 100 iterations
    - _Requirements: 11.4, 11.5, 11.6, 11.7, 11.8, 11.9, 12.6, 12.7, 12.11_

  - [x] 20.3 Write property test for source-preference value validation
    - `# Feature: multi-server-library-sharing, Property 19: Preference and playback-mode value validation` (Source_Preference half)
    - Generate valid/invalid preference values; assert persist-and-apply iff valid, else reject leaving existing value unchanged
    - **Validates: Requirements 11.10** (Property 19, Source_Preference half), min 100 iterations
    - _Requirements: 11.10_

  - [x] 20.4 Wire Source_Preference selection into `Path_Resolver`
    - Before resolving, when the same content is reachable from multiple sources, use `SourcePreference.select` to choose the copy; fall back to next source when the selected one is unavailable
    - _Requirements: 8.13, 11.6, 12.6, 12.7_

  - [x] 20.5 Add source-preference settings endpoint
    - Add controller action to read/update the user's source preference with validation error handling; add route
    - _Requirements: 11.3, 11.10_

- [x] 21. Phase 3 checkpoint
  - Ensure all tests pass, ask the user if questions arise.

---

## Phase 4 — Output devices, server-driven playback, client casting, playback modes
**Requirements: 13, 14, 16, 17, 18. Properties: 19 (Playback_Mode half), 20, 21, 23.**
HIGH RISK: AirPlay/Chromecast protocols and multi-room sync have no mature pure-Ruby stack. All wire-protocol work is isolated behind an out-of-process **playback sidecar**; Rails owns session state (property-tested), the sidecar owns framing (integration/smoke only, depends on external components).

- [x] 22. Playback schema and playback mode setting
  - [x] 22.1 Create playback tables and add playback-mode setting
    - Migration: `output_devices` (`identifier`, `name`, `protocol`, `requires_password`, `reachable_at`), `playback_sessions` (`user_id`, `state`, `current_song_id`, `position`, serialized `active_output_device_ids`)
    - Add per-user `playback_mode` setting (`client_cast`/`server_playback`) via `has_setting`
    - _Requirements: 13.1, 14.1, 14.15, 16.1, 16.2, 16.3_

  - [x] 22.2 Write property test for playback-mode value validation
    - `# Feature: multi-server-library-sharing, Property 19: Preference and playback-mode value validation` (Playback_Mode half)
    - Generate valid/invalid playback-mode values; assert record iff `client_cast`/`server_playback`, else reject leaving existing mode unchanged
    - **Validates: Requirements 16.4** (Property 19, Playback_Mode half), min 100 iterations
    - _Requirements: 16.4_

- [x] 23. Device discovery (sidecar boundary — integration-tested)
  - [x] 23.1 Implement `DeviceDiscovery` over the sidecar boundary
    - Create `app/models/device_discovery.rb` calling the playback sidecar over local HTTP/IPC; classify each device as exactly one of `airplay`/`chromecast`, record password requirement, add/remove devices as advertisements appear/disappear; empty set + "unavailable" indication when the sidecar is absent
    - HIGH RISK: depends on external sidecar (mDNS/`castv2`/AirTunes); Rails side is a thin translator
    - _Requirements: 13.1, 13.2, 13.3, 13.4, 13.5, 13.6_

  - [x] 23.2 Write property test for output-device classification
    - `# Feature: multi-server-library-sharing, Property 23: Output devices are classified with exactly one protocol`
    - Generate discovered-device sets (incl. empty); assert each device classified as exactly one protocol with password requirement reported
    - **Validates: Requirements 13.2, 13.6** (Property 23), min 100 iterations
    - _Requirements: 13.2, 13.6_

  - [x] 23.3 Write integration/smoke tests for discovery
    - Against the sidecar with mocked mDNS advertisements: verify discovery, device removal on de-advertisement (13.3), and graceful empty set when the sidecar is absent (13.5)
    - Integration/smoke tests (NOT property-based) — mDNS/network path, external component
    - _Requirements: 13.1, 13.3, 13.4, 13.5_

- [x] 24. Server-driven playback state machine
  - [x] 24.1 Implement `PlaybackController` + `Playback_Session` state machine
    - Create session state machine (`stopped｜playing｜paused`): device selection (reject unreachable, leave devices unchanged), play/resume (reject when no active device; leave state unchanged), pause (retain song+position), stop (clear position), volume; when the last active device is lost during `playing`, transition to `stopped` with a reason; resume-after-pause returns to `playing` with retained song/position
    - Keep pure state logic separate from sidecar audio dispatch
    - _Requirements: 14.1, 14.3, 14.4, 14.5, 14.6, 14.11, 14.12, 14.13, 14.14, 14.15, 14.16, 14.17, 14.18, 14.19_

  - [x] 24.2 Write property test for session state machine
    - `# Feature: multi-server-library-sharing, Property 20: Playback and cast sessions maintain a valid state and correct resume transition`
    - Generate random control-operation sequences; assert state always in `{stopped,playing,paused}`, play/resume with no device rejected leaving state unchanged, last-device-lost during `playing` → `stopped`, resume-after-pause → `playing` with retained song/position
    - **Validates: Requirements 14.11, 14.12, 14.13, 14.14, 14.15, 14.16, 17.11, 17.12, 17.14, 17.16** (Property 20), min 100 iterations
    - _Requirements: 14.11, 14.12, 14.13, 14.14, 14.15, 14.16_

  - [x] 24.3 Write integration tests for the server playback audio path
    - Against the sidecar: verify audio dispatched to devices, password-protected devices require credentials (14.7, 14.8), local vs remote decoding paths (14.9, 14.10); multi-room sync (14.2) flagged as hardware-in-the-loop / manual smoke test
    - Integration/smoke tests (NOT property-based) — HIGH RISK protocol path, external component
    - _Requirements: 14.2, 14.7, 14.8, 14.9, 14.10_

- [x] 25. Client casting state machine
  - [x] 25.1 Implement `Cast_Session` client-side state machine + controller
    - Implement cast session state (`stopped｜playing｜paused`): create session with target device, play/resume/pause/stop/volume mirroring the server session semantics; reject unreachable target → `stopped`; target disconnect during `playing` → `stopped`; resume-after-pause → `playing` with retained song/position; mirror to a lightweight server bookkeeping record
    - _Requirements: 17.1, 17.2, 17.5, 17.6, 17.7, 17.8, 17.11, 17.12, 17.14, 17.16, 18.2, 18.3_

  - [x] 25.2 Write integration tests for the client casting device path
    - Client-side integration tests: obtaining audio from `resolved_stream_path` incl. remote (17.3, 17.4), password-protected AirPlay (17.9, 17.10), 30s stream timeout (17.13); state logic itself is covered by Property 20
    - Integration/smoke tests (NOT property-based) — device casting path, external component
    - _Requirements: 17.3, 17.4, 17.9, 17.10, 17.13_

- [x] 26. Playback mode selection and mode exclusivity
  - [x] 26.1 Implement playback-mode selection and exclusivity invariants
    - Add mode selection endpoints (web + app) with validation; enforce that each activity is exactly one mode, `client_cast` managed only by a `Cast_Session` (client is audio source), `server_playback` managed only by a `Playback_Session` (server is audio source), never both; every concurrent `client_cast` activity is managed
    - _Requirements: 16.2, 16.3, 16.5, 16.6, 16.7, 16.8, 18.1, 18.4, 18.5, 18.6_

  - [x] 26.2 Write property test for playback-mode exclusivity
    - `# Feature: multi-server-library-sharing, Property 21: Playback mode is exclusive and determines the audio source`
    - Generate sets of concurrent activities; assert each is exactly one mode, correct audio source per mode, never managed by both session types, every concurrent `client_cast` activity managed
    - **Validates: Requirements 16.5, 16.6, 16.7, 18.1, 18.4, 18.5, 18.6** (Property 21), min 100 iterations
    - _Requirements: 16.5, 16.6, 16.7, 18.1, 18.4, 18.5, 18.6_

- [x] 27. Phase 4 checkpoint
  - Ensure all tests pass, ask the user if questions arise.

---

## Phase 5 — DAAP/RSP media client serving
**Requirements: 15. Property: 22.**
HIGHEST protocol risk: DAAP (iTunes) and RSP (Roku) are legacy protocols with no maintained Ruby servers; likely front/embed an external media server (owntone-style) behind Black Candy auth. Deliberately last so the rest of the platform is stable.

- [x] 28. DAAP/RSP settings and authorized-content selection
  - [x] 28.1 Add DAAP/RSP enable settings
    - Add `enable_daap` / `enable_rsp` boolean `Setting`s via the `has_setting` pattern, independently toggleable
    - _Requirements: 15.3_

  - [x] 28.2 Implement authorized-content selection for media clients
    - Create the content-selection logic returning only local-library content the authenticated account is authorized to access (reuse the Library_Access_Controller model), excluding all remote-library content; content stops being served when authorization is revoked
    - _Requirements: 15.8, 15.9, 15.10_

  - [x] 28.3 Write property test for authorization containment
    - `# Feature: multi-server-library-sharing, Property 22: DAAP/RSP served content is local and authorized`
    - Generate library/authorization configurations; assert served content is a subset of authorized local content, contains no remote content, and drops a library's content when authorization is revoked
    - **Validates: Requirements 15.8, 15.9, 15.10** (Property 22), min 100 iterations
    - _Requirements: 15.8, 15.9, 15.10_

- [x] 29. DAAP/RSP services
  - [x] 29.1 Implement `DAAP_Service` and `RSP_Service` behind settings and auth
    - Wire the services (fronting/embedding an external media server) behind the enable settings and the server's existing authentication model; refuse connections when disabled or auth fails, serving no content
    - HIGHEST RISK: legacy binary/HTTP protocols, external component dependency
    - _Requirements: 15.1, 15.2, 15.4, 15.5, 15.6, 15.7_

  - [x] 29.2 Write integration/smoke tests for DAAP/RSP serving
    - Against real DAAP (iTunes)/RSP (Roku) clients or a conformance harness: verify browse/download-and-play when enabled, connection refused when disabled (15.4, 15.5), auth failure serves no content (15.7); content-selection logic itself is covered by Property 22
    - Integration/smoke tests (NOT property-based) — HIGHEST RISK protocol path, external component
    - _Requirements: 15.1, 15.2, 15.4, 15.5, 15.6, 15.7_

- [x] 30. Final checkpoint
  - Ensure all tests pass, ask the user if questions arise.

## Notes

- Tasks marked with `*` are optional test sub-tasks and can be skipped for a faster MVP; core implementation tasks are never optional.
- Each task references specific requirement clauses and, where applicable, the design correctness property it validates.
- Every property test uses the tag `# Feature: multi-server-library-sharing, Property {number}: {property_text}` and runs a minimum of 100 iterations (harness from task 1.1).
- Protocol/network paths that the design marks NOT property-testable (federation, mDNS device discovery, server playback audio path, client casting device path, DAAP/RSP) are covered by integration/smoke tests instead.
- High-risk, externally-dependent work is concentrated in Phase 4 (AirPlay/Chromecast, multi-room sync) and Phase 5 (DAAP/RSP), isolated behind sidecar/service boundaries and sequenced last.
- Phases are independently shippable; each ends with a checkpoint.

## Task Dependency Graph

```json
{
  "waves": [
    { "id": 0, "tasks": ["1.1", "2.1"] },
    { "id": 1, "tasks": ["2.2", "2.3"] },
    { "id": 2, "tasks": ["2.4", "2.5", "3.1", "4.1"] },
    { "id": 3, "tasks": ["3.2", "4.2", "4.5"] },
    { "id": 4, "tasks": ["4.3", "4.4", "4.6", "5.1"] },
    { "id": 5, "tasks": ["5.2", "8.1"] },
    { "id": 6, "tasks": ["5.3", "5.4", "6.1", "8.2", "9.1"] },
    { "id": 7, "tasks": ["5.5", "5.6", "6.2", "9.2", "9.3", "9.4", "10.1"] },
    { "id": 8, "tasks": ["9.5", "10.2", "11.1", "11.3", "14.1", "14.4"] },
    { "id": 9, "tasks": ["10.3", "11.2", "11.4", "12.1", "14.2", "14.3", "14.5"] },
    { "id": 10, "tasks": ["12.2", "12.3", "13.1", "15.1", "15.2", "16.1"] },
    { "id": 11, "tasks": ["15.3", "16.2", "18.1"] },
    { "id": 12, "tasks": ["18.2", "19.1"] },
    { "id": 13, "tasks": ["19.2", "19.3", "20.1"] },
    { "id": 14, "tasks": ["20.2", "20.3", "20.4", "20.5", "22.1"] },
    { "id": 15, "tasks": ["22.2", "23.1", "24.1", "25.1"] },
    { "id": 16, "tasks": ["23.2", "23.3", "24.2", "24.3", "25.2", "26.1"] },
    { "id": 17, "tasks": ["26.2", "28.1", "28.2"] },
    { "id": 18, "tasks": ["28.3", "29.1"] },
    { "id": 19, "tasks": ["29.2"] }
  ]
}
```
