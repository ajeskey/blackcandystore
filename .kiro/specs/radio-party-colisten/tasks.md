# Implementation Plan: Radio Stations, Party & Co-listen Modes

## Overview

This plan implements the three social-listening capabilities on top of the existing
Black Candy Store platform, reusing its proven seams: `LibraryAccess` /
`User#authorized_library_ids` for authorization, `AccessGrant` for share-link and
stream tokens, the `Authentication` dual-path (cookie + Bearer) for guest tokens,
`PlaybackController` / `PlaybackSidecar` for shared-speaker output, `has_setting`
for global config, and the `Integrations::Service` / `PlaybackSidecar` loopback
client pattern for the out-of-process Broadcaster.

> The AI DJ add-on is intentionally **out of scope** for this spec and deferred to a
> separate future specification; no task here depends on it.

The work is ordered so each phase ends in a verifiable state:

1. **Data models + migrations** — the schema every other phase builds on.
2. **Pure logic seams** — Program_Sequencer, token issuance/validation, lifecycle
   & concurrency, quota/duplicate/attribution, authorization/guest-access. The
   design's 30 correctness properties target these deterministic seams, so they
   are property-tested here (Minitest + `rantly` via `check_property`, ≥100
   iterations) before any I/O is wired in.
3. **Controllers / API surface** + guest auth and stream auth concerns.
4. **Broadcaster** out-of-process service + the Rails↔Broadcaster control contract
   + reverse-proxy stream endpoint.
5. **Party device dispatch** via `PlaybackController`/`PlaybackSidecar`.
6. **Co-listen fan-out**.
7. **Web UI** (ERB + Hotwire/Turbo/Stimulus).
8. **Wiring / config / docs**.

Conventions: property tests live in `test/**/*_property_test.rb`, each tagged
`# Feature: radio-party-colisten, Property {n}: {property text}` and run via
`check_property(iterations: 100)`. Sub-tasks marked `*` are optional (tests) and
are not implemented by the execution agent unless explicitly requested; every
non-`*` sub-task is implemented.

## Tasks

- [x] 1. Phase 1 — Data models and migrations
  - [x] 1.1 Create migrations for `radio_stations` and `station_source_criteria`
    - `radio_stations`: `name`, `user_id`, `state` (default `stopped`), `stream_visibility` (default `authenticated`), `listener_limit` (nullable), timestamps + indexes
    - `station_source_criteria`: `radio_station_id`, `criterion_type` (`artist`/`song`/`genre`), `artist_id`/`song_id`/`genre` value column
    - _Requirements: 1.1, 1.2, 10.1, 11.1, 11.6_
  - [x] 1.2 Create migrations for `party_sessions`, `co_listen_sessions`, `shared_playlists`, `shared_playlist_entries`
    - `party_sessions`: `user_id`, `state`, `session_duration_kind`, `session_duration_value`, `duplicate_policy`, `max_guests`, `guest_add_quota`, `guest_add_rate_per_minute`, `shared_library_ids` (jsonb)
    - `co_listen_sessions`: same columns + `listener_limit` (no `stream_visibility`)
    - `shared_playlists`: polymorphic `sessionable`
    - `shared_playlist_entries`: `shared_playlist_id`, `song_id`, `position`, `added_by_guest_id` (nullable), `added_by_user_id` (nullable), `guest_display_name`
    - _Requirements: 4.1, 4.3, 5.9, 5.10, 5.11, 5.12, 6.3, 7.1, 11.6_
  - [x] 1.3 Create migrations for `guests`, `share_links`, `stream_tokens` and add the `has_setting` global setting
    - `guests`: polymorphic `sessionable`, `display_name`, `guest_token_digest`, `admitted_at`, `removed_at`, `add_count` + rate window column
    - `share_links`: polymorphic `sessionable`, `access_grant_id`
    - `stream_tokens`: `radio_station_id`, `token_digest`, `status`
    - Setting: `max_concurrent_streams`
    - _Requirements: 4.2, 5.13, 8.1, 8.7, 10.5, 11.5_
  - [x] 1.4 Implement `RadioStation` and `StationSourceCriterion` models
    - `RadioStation`: name validation (trimmed length 1..255), `belongs_to :user`, `state`/`stream_visibility` enums, associations (`station_source_criteria`, `stream_token`)
    - `eligible_songs`: songs matching criteria intersected with `owner.authorized_library_ids`; reject create/update when empty; recompute on criteria change
    - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.9_
  - [x] 1.5 Write property tests for `RadioStation` validation seam
    - **Property 1: Eligible songs are exactly the authorized intersection** — Validates: Requirements 1.2, 1.4, 1.5
    - **Property 2: A station is accepted iff it selects at least one authorized Song** — Validates: Requirements 1.3, 1.9
    - **Property 3: Station name validity** — Validates: Requirements 1.6
  - [x] 1.6 Implement `PartySession` and `CoListenSession` models
    - Duration fields (`hours`/`days`/`perpetual`), guest config (`max_guests`, quota, rate, `duplicate_policy`), `shared_library_ids` validated as subset of host `authorized_library_ids`, `state` enums, associations (`shared_playlist`, `guests`, `share_links`); `CoListenSession` adds `listener_limit`
    - _Requirements: 4.1, 4.3, 4.7, 5.9, 5.10, 5.11, 7.1, 7.7, 10.7, 11.6_
  - [x] 1.7 Write property test for shared-library scoping
    - **Property 13: Shared libraries are a subset of the host's authorized libraries** — Validates: Requirements 4.7
  - [x] 1.8 Implement `SharedPlaylist` and `SharedPlaylistEntry` models
    - Polymorphic `sessionable`; entry `position` ordering, adder attribution columns (`added_by_guest_id`, `added_by_user_id`, `guest_display_name`); retained after teardown
    - _Requirements: 5.12, 6.3, 12.3_
  - [x] 1.9 Write unit tests for shared playlist models
    - Ordering, attribution columns, polymorphic association integrity
    - _Requirements: 5.12, 6.3_
  - [x] 1.10 Implement `Guest`, `ShareLink`, `StreamToken` models and the `has_setting` addition
    - `Guest`: keyed `guest_token_digest`, `removed_at`, quota accounting; `ShareLink` `belongs_to :access_grant` (one grant per shared library); `StreamToken` keyed digest + `status`; register `max_concurrent_streams` via `has_setting`
    - _Requirements: 5.13, 8.1, 8.7, 10.5, 11.5_
  - [x] 1.11 Write unit tests for `Guest`/`ShareLink`/`StreamToken` associations and CRUD
    - Digest-only persistence, association wiring, setting default
    - _Requirements: 8.7, 10.5, 11.5_

- [x] 2. Phase 2a — Program_Sequencer (pure seam)
  - [x] 2.1 Implement `ProgramSequencer` (`app/models/program_sequencer.rb`)
    - Pure/deterministic `next` given eligible-song set (or Shared_Playlist) + recently-played history: never returns an ineligible item, re-selects from full set after exhaustion, loops a playlist at its end, yields a `:continuity` directive when nothing is resolvable
    - _Requirements: 2.2, 2.3, 2.5, 6.7, 7.8, 7.9_
  - [x] 2.2 Write property test — sequencer always eligible, never exhausts
    - **Property 5: Program_Sequencer always selects an eligible item and never exhausts** — Validates: Requirements 2.2, 2.3
  - [x] 2.3 Write property test — continuity when nothing resolvable
    - **Property 6: Continuity when nothing is resolvable** — Validates: Requirements 2.5, 7.9
  - [x] 2.4 Write property test — playlist loops at its end
    - **Property 7: Shared_Playlist loops at its end** — Validates: Requirements 6.7, 7.8

- [x] 3. Phase 2b — Token issuance and validation (pure seam)
  - [x] 3.1 Implement `StreamTokenService` and stream-visibility authorization decision
    - Radio `StreamToken`: keyed-digest issuance, constant-time verify (mirroring `AccessGrant.authenticate_token`), rotate/revoke invalidation; co-listen tokens derived per-participant via `signed_id(purpose: :colisten_stream)` scoped to session + shared libraries; pure `stream_authorized?` decision over `public` / valid-token / valid-account / guest-derived-token cases
    - _Requirements: 3.4, 3.5, 3.7, 11.2, 11.3, 11.4, 11.5, 11.8, 11.9_
  - [x] 3.2 Implement `ShareLinkService` backed by `AccessGrant`
    - Generate `AccessGrant`-backed share link; map `session_duration` → `expires_at` (`created_at + hours/days`, nil for `perpetual`); revoke to block new joins
    - _Requirements: 4.2, 4.4, 4.5, 4.6, 8.1, 8.3, 8.5_
  - [x] 3.3 Write property test — token keyed-digest lifecycle
    - **Property 10: Tokens are persisted only as keyed digests and honor their lifecycle** — Validates: Requirements 8.7, 11.5
  - [x] 3.4 Write property test — stream authorization by visibility
    - **Property 9: Stream authorization by visibility** — Validates: Requirements 3.4, 3.5, 3.7, 11.2, 11.3, 11.4
  - [x] 3.5 Write property test — co-listen stream authorization tracks guest validity
    - **Property 27: Co-listen stream authorization tracks guest access validity** — Validates: Requirements 11.8, 11.9
  - [x] 3.6 Write property test — session duration maps to grant expiration
    - **Property 12: Session duration maps to grant expiration** — Validates: Requirements 4.4, 4.5, 8.3

- [x] 4. Phase 2c — Lifecycle and concurrency (pure seam)
  - [x] 4.1 Implement `StationLifecycleService` / `SessionLifecycleService`
    - `Station_State` (`stopped`/`started`) and `Session_State` (`active`/`ended`) transitions; owner/admin authority; Admin-configurable concurrency cap enforced at start/activate against live-broadcast count (capacity error leaves state unchanged); pure `audio_deliverable?` decision (audio iff started/active); listener-limit admission decision
    - _Requirements: 9.6, 10.1, 10.2, 10.5, 10.6, 10.7, 10.8, 11.7_
  - [x] 4.2 Implement `ResumeStreamsJob` resume-decision logic
    - Pure decision of which persisted stations/sessions to re-establish on boot: exactly `started` stations and `active`, non-expired co-listen sessions up to the concurrency cap; expired sessions treated as ended
    - _Requirements: 10.4, 10.10, 12.4_
  - [x] 4.3 Write property test — audio delivered iff broadcast running
    - **Property 8: Audio is delivered iff the broadcast is running** — Validates: Requirements 3.6, 9.6
  - [x] 4.4 Write property test — concurrency cap on start/activate
    - **Property 25: Concurrency cap on start/activate** — Validates: Requirements 10.5, 10.6, 10.7
  - [x] 4.5 Write property test — restart resume re-establishes eligible broadcasts
    - **Property 26: Restart resume re-establishes exactly the eligible broadcasts** — Validates: Requirements 10.4, 10.10, 12.4
  - [x] 4.6 Write property test — listener limit admission
    - **Property 11: Listener limit admission** — Validates: Requirements 11.7

- [x] 5. Phase 2d — Quota, duplicate, and attribution logic (pure seam)
  - [x] 5.1 Implement `SharedPlaylistAddService`
    - Enforce per-Guest add quota and add rate (reject excess with rate-limit error, no side effects), apply duplicate policy (`reject`/`allow`, reject leaves playlist unchanged), append with adder attribution (guest display name or host)
    - _Requirements: 5.9, 5.10, 5.12_
  - [x] 5.2 Write property test — quota/rate enforced without side effects
    - **Property 19: Per-Guest add quota and rate are enforced without side effects on rejection** — Validates: Requirements 5.9
  - [x] 5.3 Write property test — duplicate policy honored
    - **Property 20: Duplicate policy is honored** — Validates: Requirements 5.10
  - [x] 5.4 Write property test — entry attributed to its adder
    - **Property 21: Every entry is attributed to its adder** — Validates: Requirements 5.12

- [x] 6. Phase 2e — Authorization and guest-access logic (pure seam)
  - [x] 6.1 Implement authorization decision predicates
    - Pure predicates for mutation/lifecycle authority (owner/host/admin), Shared_Playlist entry mutation authority (host any entry; guest only own entry), and host-only device selection + transport control (stop/pause/skip)
    - _Requirements: 1.8, 6.2, 6.5, 6.6, 6.8, 7.10, 10.3, 10.9_
  - [x] 6.2 Implement `GuestAccess` resolution logic
    - Admission (usable `AccessGrant` + capacity below `max_guests`), library scoping with existence-hiding not-found, live-state gating (active/unexpired/not-removed), terminal revocation, token→Guest identity binding, and retained-playlist host-only access
    - _Requirements: 5.1, 5.3, 5.4, 5.5, 5.6, 5.8, 5.11, 5.13, 8.2, 8.4, 8.6, 12.2, 12.3_
  - [x] 6.3 Write property test — mutation and lifecycle authority
    - **Property 4: Mutation and lifecycle authority** — Validates: Requirements 1.8, 10.3, 10.9
  - [x] 6.4 Write property test — guest admission requires usable grant and capacity
    - **Property 14: Guest admission requires a usable grant and available capacity** — Validates: Requirements 5.1, 5.11
  - [x] 6.5 Write property test — guest access strictly scoped with existence-hiding
    - **Property 15: Guest access is strictly scoped to shared libraries with existence-hiding** — Validates: Requirements 5.3, 5.4, 5.5, 8.2, 8.6
  - [x] 6.6 Write property test — guest authorization depends on live session and guest state
    - **Property 16: Guest authorization depends on live session and guest state** — Validates: Requirements 5.6, 5.8, 8.4, 12.2
  - [x] 6.7 Write property test — revocation is terminal and blocks only new joins
    - **Property 17: Revocation is terminal and blocks only new joins** — Validates: Requirements 4.6, 8.5
  - [x] 6.8 Write property test — guest identity is the token→Guest binding
    - **Property 18: Guest identity is the token→Guest binding** — Validates: Requirements 5.13
  - [x] 6.9 Write property test — playlist mutation authority
    - **Property 22: Playlist mutation authority** — Validates: Requirements 6.6
  - [x] 6.10 Write property test — host-only device and transport control
    - **Property 23: Host-only device selection and transport control** — Validates: Requirements 6.2, 6.5, 6.8, 7.10
  - [x] 6.11 Write property test — retained playlist is host-only after teardown
    - **Property 30: Retained playlist is host-only after teardown** — Validates: Requirements 12.3

- [x] 7. Checkpoint — pure seams
  - Ensure all tests pass, ask the user if questions arise.

- [x] 8. Phase 3 — Controllers, API surface, and access concerns
  - [x] 8.1 Implement `GuestAccess` and `StreamAuthorization` controller concerns
    - `GuestAccess`: resolve non-cookie Bearer Guest_Token → `Guest` (keyed-digest lookup), reject removed/expired/ended, scope reads/adds to shared libraries, existence-hiding not-found; `StreamAuthorization`: connect-time validation layered like `SidecarStreamAccess`
    - _Requirements: 5.3, 5.4, 5.5, 5.6, 5.8, 9.2, 9.3, 12.2_
  - [x] 8.2 Implement `RadioStationsController` (HTML + JSON)
    - CRUD, start/stop lifecycle, stream-token rotate/revoke; identical authorization for HTML and JSON; client-agnostic JSON representation; Stream_Endpoint URL exposed regardless of state
    - _Requirements: 1.1, 1.7, 1.8, 9.1, 9.4, 9.5, 9.6, 10.1, 10.2, 10.3, 11.1, 11.5, 11.6_
  - [x] 8.3 Implement `CoListenSessionsController` (HTML + JSON)
    - CRUD, activate/deactivate lifecycle, share-link generation; JSON representation; Stream_Endpoint URL exposed regardless of state
    - _Requirements: 7.1, 7.7, 9.1, 9.4, 9.5, 9.6, 10.7, 10.8, 10.9, 11.6_
  - [x] 8.4 Implement `PartySessionsController` (HTML + JSON)
    - CRUD, share-link generation, output-device selection (host-only), transport control (host-only), revocation; explicitly no Stream_Endpoint
    - _Requirements: 4.1, 4.2, 4.6, 4.7, 6.2, 6.5, 6.8, 9.1, 9.4, 9.5, 9.7_
  - [x] 8.5 Implement guest join and Shared_Playlist contribution controllers
    - Share-link open → admission + Guest_Token issuance; add/remove/reorder entries with quota/duplicate/authority enforcement; individual-song streaming only (no download/export/bulk/file-path)
    - _Requirements: 5.1, 5.2, 5.7, 5.9, 5.10, 5.12, 6.6_
  - [x] 8.6 Add routes for all station/session/guest/stream endpoints
    - _Requirements: 9.1, 9.6, 9.7_
  - [x] 8.7 Write integration test — authorization independent of response format
    - **Property 28: Authorization is independent of response format** — Validates: Requirements 9.5
  - [x] 8.8 Write integration test — party sessions never expose a stream endpoint
    - **Property 29: Party sessions never expose a stream endpoint** — Validates: Requirements 9.7
  - [x] 8.9 Write controller unit/integration tests for happy paths
    - Station/session CRUD, guest admission, share-link generation, device selection
    - _Requirements: 1.1, 4.1, 4.2, 5.1, 6.1, 7.1_

- [x] 9. Phase 4 — Broadcaster service, control contract, and stream endpoint
  - [x] 9.1 Scaffold the Broadcaster out-of-process service (sibling to playback-sidecar)
    - Continuous ffmpeg-based constant-bitrate MP3 encode loop that advances with zero listeners; Icecast/SHOUTcast-style loopback listen endpoint serving the current position to zero-or-more listeners; listener-limit accounting; holds no authoritative domain state
    - _Requirements: 2.1, 2.4, 2.6, 3.1, 3.2, 3.3, 11.7_
  - [x] 9.2 Implement the Rails↔Broadcaster control client
    - Loopback HTTP JSON client (`POST /broadcasts`, `DELETE /broadcasts/:id`, `POST /broadcasts/:id/next`, `GET /broadcasts/:id/status`) with injectable client and transport-error → domain-error translation mirroring `PlaybackSidecar` (`Unavailable`)
    - _Requirements: 2.2, 2.5, 10.2, 12.1_
  - [x] 9.3 Wire lifecycle services to the Broadcaster control API
    - On start/activate spin up a broadcast (after concurrency cap); on stop/teardown end it; drive `POST /next` from `ProgramSequencer` decisions; `ResumeStreamsJob` re-establishes broadcasts on boot
    - _Requirements: 2.1, 2.2, 2.3, 2.5, 10.1, 10.2, 10.4, 10.7, 10.8, 10.10, 12.1_
  - [x] 9.4 Implement `StreamEndpointController` reverse-proxy with connect-time auth
    - Resolve station/session, verify started/active (else 503 not-broadcasting), enforce visibility/token/account/guest-token auth (else 401), enforce listener limit (else 503 capacity), then reverse-proxy the Broadcaster's loopback fan-out from the current position
    - _Requirements: 3.2, 3.3, 3.4, 3.5, 3.6, 3.7, 7.4, 7.5, 7.6, 11.2, 11.3, 11.4, 11.7_
  - [x] 9.5 Write Broadcaster integration/smoke tests
    - Zero-listener encode advances; single then multiple listeners each served `audio/mpeg` from current position; restart resume re-establishes broadcasts (injected fakes, representative examples)
    - _Requirements: 2.1, 2.4, 2.6, 3.1, 3.2, 3.3, 7.2, 7.4, 7.5, 7.6_
  - [x] 9.6 Write stream-endpoint integration tests
    - Not-broadcasting 503, authenticated-without-token 401, public bypass, listener-limit capacity without disrupting existing listeners
    - _Requirements: 3.5, 3.6, 3.7, 11.7_

- [x] 10. Checkpoint — streaming end-to-end
  - Ensure all tests pass, ask the user if questions arise.

- [x] 11. Phase 5 — Party device dispatch
  - [x] 11.1 Implement Party playback dispatch via `PlaybackController`/`PlaybackSidecar`
    - Dispatch Shared_Playlist current song + signed stream token to host-selected `OutputDevice`s through `POST /play`; play in current order; loop at end; continue on remaining devices when one drops and stop when none remain
    - _Requirements: 6.1, 6.3, 6.4, 6.7_
  - [x] 11.2 Write property test — device-loss continuation
    - **Property 24: Device-loss continuation** — Validates: Requirements 6.4
  - [x] 11.3 Write integration test for device dispatch
    - Assert `POST /play` shape with signed stream token using a fake `PlaybackSidecar::Client`
    - _Requirements: 6.1, 6.3_

- [x] 12. Phase 6 — Co-listen fan-out
  - [x] 12.1 Wire Co_Listen_Session Shared_Stream to the Broadcaster
    - Drive Broadcaster from the Shared_Playlist via `ProgramSequencer` (advance, loop at end, continuity while empty), and expose per-participant guest-derived stream tokens for connect
    - _Requirements: 7.2, 7.3, 7.4, 7.5, 7.6, 7.8, 7.9, 11.8, 11.9_
  - [x] 12.2 Write co-listen fan-out integration/smoke test
    - Per-participant connect from current position; empty-playlist continuity then playback on first add
    - _Requirements: 7.4, 7.6, 7.9_

- [x] 13. Checkpoint — party and co-listen
  - Ensure all tests pass, ask the user if questions arise.

- [x] 14. Phase 7 — Web UI (ERB + Hotwire/Turbo/Stimulus)
  - [x] 14.1 Build Radio_Station configuration and player views
    - Station CRUD form, source-criteria builder, start/stop controls, Stream_Endpoint URL display; Stimulus player controller reusing `player.js` structure
    - _Requirements: 1.1, 3.1, 9.4, 10.1, 11.1_
  - [x] 14.2 Build Party_Session host and guest views
    - Host: create/config, share-link, device selection, transport, playlist manage; Guest: join via share link, add songs, remove own entries; Turbo streams for playlist updates reusing `playlist.js`
    - _Requirements: 4.1, 4.2, 5.1, 5.2, 5.12, 6.1, 6.6_
  - [x] 14.3 Build Co_Listen_Session host and participant views
    - Host activate/deactivate + config; participant join, per-device player, collaborative add
    - _Requirements: 7.1, 7.3, 7.5_
  - [x] 14.4 Write system/integration tests for key UI flows
    - Station create + start, guest join + add via Turbo
    - _Requirements: 1.1, 5.1, 5.2_

- [x] 15. Phase 8 — Wiring, config, and operator docs
  - [x] 15.1 Add configuration and process wiring
    - `BROADCASTER_URL` (loopback) and setting defaults; a `Procfile.dev` entry for the Broadcaster; boot-time `ResumeStreamsJob` registration
    - _Requirements: 10.4, 10.10_
  - [x] 15.2 Create operator setup documentation file
    - `docs/` markdown covering the Broadcaster service and how stations/sessions stream
    - _Requirements: 3.1, 9.6_
  - [x] 15.3 Write end-to-end wiring smoke test
    - Boot resume path re-establishes a started station and an active co-listen session via fakes
    - _Requirements: 10.4, 10.10_

- [x] 16. Final checkpoint
  - Ensure all tests pass, ask the user if questions arise.

## Notes

- Sub-tasks marked with `*` are optional (tests) and can be skipped for a faster MVP; core implementation sub-tasks are never optional.
- Every task references specific requirement clauses; property-test tasks additionally cite the design Property number they validate.
- Property-based tests use Minitest + `rantly` via the existing `check_property` / `PropertyHelper` harness at ≥100 iterations, tagged `# Feature: radio-party-colisten, Property {n}: {text}`, matching `test/models/*_property_test.rb`.
- The 30 correctness properties are all covered exactly once by a property-test sub-task in Phases 1–6 (the pure logic seams they target).
- Continuous encoding, byte fan-out, and device wire protocols are covered by integration/smoke tests (injected fakes / `webmock`), not property tests, per the design's Testing Strategy.
- Checkpoints (tasks 7, 10, 13, 16) provide incremental validation between phases.

## Task Dependency Graph

```json
{
  "waves": [
    { "id": 0, "tasks": ["1.1", "1.2", "1.3"] },
    { "id": 1, "tasks": ["1.4", "1.6", "1.8", "1.10"] },
    { "id": 2, "tasks": ["1.5", "1.7", "1.9", "1.11", "2.1", "3.1", "3.2", "4.1", "4.2", "5.1", "6.1", "6.2"] },
    { "id": 3, "tasks": ["2.2", "2.3", "2.4", "3.3", "3.4", "3.5", "3.6", "4.3", "4.4", "4.5", "4.6", "5.2", "5.3", "5.4", "6.3", "6.4", "6.5", "6.6", "6.7", "6.8", "6.9", "6.10", "6.11"] },
    { "id": 4, "tasks": ["8.1"] },
    { "id": 5, "tasks": ["8.2", "8.3", "8.4", "8.5", "8.6"] },
    { "id": 6, "tasks": ["8.7", "8.8", "8.9", "9.1", "9.2", "11.1", "14.1", "14.2", "14.3"] },
    { "id": 7, "tasks": ["9.3", "9.4", "11.2", "11.3"] },
    { "id": 8, "tasks": ["9.5", "9.6", "12.1", "15.1"] },
    { "id": 9, "tasks": ["12.2", "14.4", "15.2", "15.3"] }
  ]
}
```
