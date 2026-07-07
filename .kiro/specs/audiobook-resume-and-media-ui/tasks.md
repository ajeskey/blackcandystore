# Implementation Plan: Audiobook Resume & Media Navigation UI

## Overview

This plan implements two user-facing capabilities on the existing Black Candy Store
platform, following the design's "thin edge, pure core" shape: controllers
authenticate and marshal, the `PlaybackPosition` model persists, and every
correctness-sensitive decision lives in a small set of **pure seams** (Ruby
POROs/modules with no I/O) shared by the API and mirrored in the Web_Player.

The work is phased so each phase ends in a verifiable state and later phases build
strictly on earlier ones:

1. **Persistence foundation** — the `playback_positions` migration, the
   `PlaybackPosition` model with its constants and validations, `User`/`Song`
   associations, and the `Song#resumable?` predicate.
2. **Pure seams** — `ResumablePolicy`, `PositionPolicy`, `PositionReconciler`,
   `ContinueListeningPolicy`, and `NavTabs`, each property-tested (Properties 1–8)
   before any I/O is wired in.
3. **API surface** — `PlaybackPositionsController`, `ContinueListeningController`,
   routes, the `OwnershipGuard`, and `song_json_builder` fields, with
   authentication / cross-user isolation / format-parity integration tests.
4. **Web_Player `PositionSync`** — recording, best-effort saving, reconcile +
   auto-seek on open, start-from-beginning, and the finished signal, with JS /
   system tests.
5. **Home Continue-listening surface** — the `ContinueListeningQuery`, Home wiring,
   the `_continue_listening` partial, enrichment context, and empty state.
6. **Navigation tabs** — the three social-listening tabs in `_nav_bar.html.erb`,
   i18n labels, and per-tab active state.

Conventions: property tests live under `test/**/*_property_test.rb`, each tagged
`# Feature: audiobook-resume-and-media-ui, Property {n}: {property text}` and run
via the existing `check_property` / `PropertyHelper` harness at a minimum of 100
iterations. Sub-tasks marked `*` are optional (tests) and are not implemented by
the execution agent unless explicitly requested; every non-`*` sub-task is
implemented. The eight correctness properties are each covered exactly once by a
property-test sub-task.

## Tasks

- [x] 1. Phase 1 — Persistence foundation
  - [x] 1.1 Create the `playback_positions` migration
    - New table keyed on `(user_id, song_id)`: `position_seconds` (float, null: false, default 0.0), `finished` (boolean, null: false, default false), timestamps
    - Unique index on `[:user_id, :song_id]`; index on `[:user_id, :updated_at]` for Continue_Listening ordering; foreign keys to `users` and `songs`
    - Deliberately separate from and unrelated to the existing playlist-index / ordering `position` columns
    - _Requirements: 6.1, 7.1_
  - [x] 1.2 Implement the `PlaybackPosition` model
    - Define constants `LONG_TRACK_THRESHOLD = 1200`, `MINIMUM_RESUME_POSITION = 10`, `FINISHED_THRESHOLD = 30`, `SAVE_INTERVAL = 10`
    - `belongs_to :user`, `belongs_to :song`, `delegate :library_id, to: :song`
    - Uniqueness validation on `song_id` scoped to `user_id`; `song_must_be_resumable` validation (Req 2.7); `position_within_duration` validation delegating to `PositionPolicy.valid_position?` (Req 2.6)
    - _Requirements: 2.4, 2.5, 2.6, 2.7_
  - [x] 1.3 Add `playback_positions` associations to `User` and `Song`, and `Song#resumable?`
    - `User has_many :playback_positions, dependent: :destroy` (Req 7.1, 7.5)
    - `Song has_many :playback_positions, dependent: :destroy`
    - `Song#resumable?` adapts the model to the pure seam: `Playback::ResumablePolicy.resumable?(audiobook: album&.audiobook?, duration: duration)`
    - _Requirements: 1.1, 1.4, 7.5_
  - [x] 1.4 Write unit tests for the model and associations
    - `Song#resumable?` derives audiobook status from `ContentClassifier` / `Album#audiobook?` (Req 1.4); `dependent: :destroy` removes a User's records on deletion (Req 7.5); uniqueness of `(user_id, song_id)`
    - _Requirements: 1.4, 7.5_

- [x] 2. Phase 2 — Pure decision seams (property-tested)
  - [x] 2.1 Implement `Playback::ResumablePolicy`
    - Pure predicate `resumable?(audiobook:, duration:)` returning `audiobook || duration.to_f >= PlaybackPosition::LONG_TRACK_THRESHOLD`
    - _Requirements: 1.1, 1.2, 1.3_
  - [x] 2.2 Write property test for resumable classification
    - **Property 1: Resumable classification**
    - **Validates: Requirements 1.1, 1.2, 1.3**
    - Generators: boolean audiobook; durations spanning 0 … well past 1200 including the boundary
  - [x] 2.3 Implement `Playback::PositionPolicy`
    - `valid_position?(position, duration)` (Req 2.6); `finished?(position:, duration:)` remaining-time backup (Req 5.1); `finished_after_save(position:, duration:, client_finished:)` recomputed per save (Req 5.4, 5.5); `resume_target(position:, duration:, finished:)` returning 0 unless a meaningful, unfinished resume point (Req 3.1–3.4)
    - _Requirements: 2.6, 3.1, 3.2, 3.3, 3.4, 5.1, 5.4, 5.5_
  - [x] 2.4 Write property test for the resume target decision
    - **Property 3: Resume target decision**
    - **Validates: Requirements 3.1, 3.2, 3.3, 3.4**
    - Generators: positions across [0, duration], finished true/false, varied durations
  - [x] 2.5 Write property test for the finished decision
    - **Property 4: Finished decision**
    - **Validates: Requirements 5.1, 5.4, 5.5**
    - Generators: positions near/below/above the finished band; client_finished true/false
  - [x] 2.6 Implement `Playback::PositionReconciler`
    - Pure `choose(server_updated_at:, client_updated_at:)` returning `:server` or `:client`, most-recent wins, ties and nil-client resolve to `:server`
    - _Requirements: 6.3, 6.5_
  - [x] 2.7 Write property test for reconciliation
    - **Property 7: Reconciliation prefers the most recent update**
    - **Validates: Requirements 6.3, 6.5**
    - Generators: pairs of timestamps including equal, nil, and ordered both ways
  - [x] 2.8 Implement `Playback::ContinueListeningPolicy`
    - `MAX_ITEMS = 20`; pure `select(records, authorized_library_ids:)` filtering by `position_seconds >= MINIMUM_RESUME_POSITION`, rejecting finished, keeping authorized libraries, ordering by `updated_at` desc, capping at 20
    - _Requirements: 4.1, 4.2, 4.3, 4.4, 4.6, 5.3_
  - [x] 2.9 Write property test for continue-listening filter/order/cap
    - **Property 5: Continue-listening filtering, ordering, and cap**
    - **Validates: Requirements 4.1, 4.2, 4.3, 4.4, 4.6, 5.3**
    - Generators: lists of records with random position/finished/library_id/updated_at; random authorized-id sets; lists longer than 20
  - [x] 2.10 Implement `NavTabs`
    - `SECTION_CONTROLLERS` map for `radio_stations` / `party_sessions` / `co_listen_sessions`; pure `active?(section, current_controller)` evaluated independently per tab
    - _Requirements: 9.4, 9.5, 9.6, 9.9, 9.10_
  - [x] 2.11 Write property test for navigation active-state
    - **Property 8: Navigation active-state is per-tab and independent**
    - **Validates: Requirements 9.4, 9.5, 9.6, 9.9, 9.10**
    - Generators: controller names including the three sections and arbitrary others

- [x] 3. Checkpoint — pure seams
  - Ensure all tests pass, ask the user if questions arise.

- [x] 4. Phase 3 — API surface (controllers, routes, JSON)
  - [x] 4.1 Implement the `OwnershipGuard` before_action concern
    - Reject with `BlackCandy::Forbidden` (403) when a targeted record's owner cannot be resolved, so corrupted ownership metadata never results in a read or write
    - _Requirements: 7.7_
  - [x] 4.2 Implement `PlaybackPositionsController` (`#show` / `#update`)
    - `#show`: return the authoritative record for `(Current.user, song)` as client-agnostic JSON `{ song_id, position_seconds, finished, updated_at }` or empty/404; reads scoped to `Current.user.playback_positions` (Req 6.2, 7.3)
    - `#update`: upsert — load Song, reject non-resumable → 422 (Req 2.7), reject invalid position → 422 leaving any existing record unchanged (Req 2.6), `find_or_initialize_by(song:)` on `Current.user.playback_positions`, apply `PositionReconciler.choose` against the client timestamp keeping the newer Server record (Req 6.5), else set `position_seconds`, recompute `finished` via `PositionPolicy.finished_after_save`, save (Req 2.4, 2.5, 5.2, 5.4, 5.5)
    - `respond_to` JSON + HTML/turbo_stream under identical authorization; wire `OwnershipGuard` as a `before_action`
    - _Requirements: 2.4, 2.5, 2.6, 2.7, 5.1, 5.4, 5.5, 6.2, 6.5, 7.3, 7.4, 8.1, 8.2, 8.3_
  - [x] 4.3 Implement `ContinueListeningController#index` (`#show`) and `ContinueListeningQuery`
    - `ContinueListeningQuery`: eager-load `Current.user.playback_positions` joined to songs/albums (most-recent ~100) and hand to `ContinueListeningPolicy.select` with `Current.user.authorized_library_ids`
    - Controller returns the client-agnostic list shape as JSON `{ items: [...] }` (Req 8.1, 8.2); empty result is a valid empty list (Req 4.7)
    - _Requirements: 4.1, 4.2, 4.3, 4.4, 4.6, 4.7, 8.1, 8.2_
  - [x] 4.4 Add routes for playback position and continue-listening endpoints
    - Nested singular `resource :playback_position, only: [:show, :update], module: :songs` under `resources :songs`; top-level `resource :continue_listening, only: [:show]`
    - _Requirements: 8.1_
  - [x] 4.5 Add `resumable` and `resume_position` fields to `song_json_builder`
    - `resumable` (bool) from `song.resumable?`; `resume_position` object `{ position_seconds, finished, updated_at }` for `Current.user` or null, so the player has resume data on open without extra round-trips
    - _Requirements: 3.1, 6.2, 8.2_
  - [x] 4.6 Write property test for position write/read round-trip
    - **Property 6: Position write/read round-trip (last write wins)**
    - **Validates: Requirements 2.4, 2.5, 6.2**
    - Exercises `PlaybackPositionsController` #update/#show at the model layer over sequences of valid saves; asserts last-write-wins and monotonic `updated_at`; uses the transactional test DB so 100+ iterations stay cheap
  - [x] 4.7 Write property test for invalid-save rejection
    - **Property 2: Invalid saves are rejected and leave persistence unchanged**
    - **Validates: Requirements 2.6, 2.7, 1.3**
    - Generators: positions <0, >duration, non-resumable songs, optional pre-existing record; asserts rejection with a validation error and any pre-existing record left exactly as it was
  - [x] 4.8 Write integration tests for auth, isolation, and format parity
    - JSON and HTML `#show`/`#update` succeed for authenticated clients with identical authorization (Req 8.1–8.3); cookie session and Bearer token each authorize, missing credentials → 401 (Req 7.2, 7.6, 6.1); cross-user isolation — User A cannot read/modify User B's record and B's record is unchanged (Req 7.3, 7.4); `OwnershipGuard` rejects an indeterminate owner (Req 7.7); continue-listening JSON returns the client-agnostic shape (Req 8.1, 8.2)
    - _Requirements: 6.1, 7.2, 7.3, 7.4, 7.6, 7.7, 8.1, 8.2, 8.3_

- [x] 5. Checkpoint — API surface
  - Ensure all tests pass, ask the user if questions arise.

- [x] 6. Phase 4 — Web_Player PositionSync
  - [x] 6.1 Implement the `PositionSync` collaborator in `player.js`
    - Mirror the constants via a data-attribute block so JS and Ruby never drift; keyed `localStorage` writes (`playbackPosition:{songId}` with a local timestamp); a mirrored `PositionReconciler.choose` and `resume_target` in JS; skip non-resumable tracks entirely
    - _Requirements: 2.1, 2.8, 3.1, 6.3_
  - [x] 6.2 Wire recording (interval + event saves) into `player_controller.js`
    - `setInterval(SAVE_INTERVAL)` writes `currentTime` to `localStorage` and PUTs to the Server while a Resumable_Track plays (Req 2.1, 2.2); also record + send on `player:pause`, `player:stop`, `player:end`, on `seek`, and on `beforeunload`/navigation (Req 2.3)
    - _Requirements: 2.1, 2.2, 2.3_
  - [x] 6.3 Implement best-effort saving
    - A failed PUT is swallowed; playback continues uninterrupted and the `localStorage` value is retained for later save/reconciliation
    - _Requirements: 2.8_
  - [x] 6.4 Implement reconcile + auto-seek on open
    - On `player:beforePlaying`, read the `localStorage` value and the song's `resume_position`, pick the more recent via the mirrored reconciler, compute `resume_target`, `player.seek(target)` after the Howl loads; if only a local value exists, PUT it so the Server catches up (Req 6.4); progress bar and timer reflect the resumed position (Req 3.6)
    - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.6, 6.3, 6.4_
  - [x] 6.5 Implement the start-from-beginning control
    - A control that sets a "skip resume" flag for the next open and seeks to 0 regardless of any stored position
    - _Requirements: 3.5_
  - [x] 6.6 Implement the finished signal
    - On `player:end`, PUT `{ finished: true }` for the Resumable_Track
    - _Requirements: 5.2_
  - [x] 6.7 Write JS/system tests for PositionSync behavior
    - With a stubbed clock, localStorage and Server saves occur at least every `SAVE_INTERVAL` and fire on pause/stop/seek/`beforeunload` (Req 2.1–2.3); a rejected `fetch` does not interrupt playback and the local value is retained (Req 2.8); seek matches `resume_target` with progress/timer reflecting it (Req 3.1, 3.6); local-only value is pushed to the Server (Req 6.4); start-from-beginning seeks 0 and skips resume (Req 3.5); `player:end` sends `finished: true` (Req 5.2)
    - _Requirements: 2.1, 2.2, 2.3, 2.8, 3.1, 3.5, 3.6, 5.2, 6.4_

- [x] 7. Checkpoint — Web_Player
  - Ensure all tests pass, ask the user if questions arise.

- [x] 8. Phase 5 — Home Continue-listening surface
  - [x] 8.1 Wire the Continue_Listening_List into `HomeController#index`
    - Load the list via `ContinueListeningQuery` for `Current.user` for server-side rendering on Home above "Recently played"
    - _Requirements: 4.5, 10.1_
  - [x] 8.2 Build the `shared/_continue_listening` partial
    - Render each item with Song name, Album name, and identifying detail (Req 10.2); when the item's Album `audiobook? && enriched?`, render the same author/publish-year context used on `albums/show.html.erb` (Req 10.3); selecting an item enqueues the Song so the player resumes from the stored position through the normal open path (Req 4.5)
    - _Requirements: 4.5, 10.1, 10.2, 10.3_
  - [x] 8.3 Implement the empty state
    - When the current User has no in-progress Resumable_Track, render an empty-state message via `empty_alert_tag` without error
    - _Requirements: 4.7, 10.4_
  - [x] 8.4 Write system/integration tests for the Home surface
    - Renders Continue_Listening items with song/album names and audiobook enrichment context (Req 10.1–10.3); empty state when there are none (Req 4.7, 10.4)
    - _Requirements: 4.7, 10.1, 10.2, 10.3, 10.4_

- [x] 9. Phase 6 — Navigation entry points
  - [x] 9.1 Add the three social-listening tabs to `_nav_bar.html.erb`
    - Add `c-tab__item` entries after Library, each `link_to` the section index (`radio_stations_path`, `party_sessions_path`, `co_listen_sessions_path`), marked `is-active` via `NavTabs.active?(section, current_controller)`; Home and Library tabs unchanged (Req 9.8)
    - _Requirements: 9.1, 9.2, 9.3, 9.4, 9.5, 9.6, 9.8, 9.9, 9.10_
  - [x] 9.2 Add i18n labels for the new tabs
    - New top-level labels `label.radio_stations`, `label.party_sessions`, `label.co_listen_sessions` mirroring the existing namespaced strings
    - _Requirements: 9.1, 9.2, 9.3_
  - [x] 9.3 Write system/integration tests for the navigation tabs
    - `_nav_bar` renders the three tabs alongside Home and Library with correct active state per section and inactive elsewhere (Req 9.1–9.6, 9.8, 9.9); hrefs resolve to the existing section controllers under their own authorization (Req 9.7)
    - _Requirements: 9.1, 9.2, 9.3, 9.4, 9.5, 9.6, 9.7, 9.8, 9.9_

- [x] 10. Final checkpoint
  - Ensure all tests pass, ask the user if questions arise.

## Notes

- Sub-tasks marked with `*` are optional (tests) and can be skipped for a faster MVP; core implementation sub-tasks are never optional.
- Every task references specific requirement clauses; property-test tasks additionally cite the design Property number they validate.
- Property-based tests use Minitest + `rantly` via the existing `check_property` / `PropertyHelper` harness at ≥100 iterations, tagged `# Feature: audiobook-resume-and-media-ui, Property {n}: {text}`, matching `test/**/*_property_test.rb`.
- The eight correctness properties are covered exactly once by a property-test sub-task: P1 (2.2), P2 (4.7), P3 (2.4), P4 (2.5), P5 (2.9), P6 (4.6), P7 (2.7), P8 (2.11).
- Browser timing/rendering, authentication/scoping boundaries, API interface shape, and view rendering are covered by integration/system/example tests per the design's Testing Strategy, not by property tests.
- Checkpoints (tasks 3, 5, 7, 10) provide incremental validation between phases.

## Task Dependency Graph

```json
{
  "waves": [
    { "id": 0, "tasks": ["1.1", "2.1", "2.3", "2.6", "2.8", "2.10"] },
    { "id": 1, "tasks": ["1.2", "2.2", "2.4", "2.5", "2.7", "2.9", "2.11", "9.1", "9.2"] },
    { "id": 2, "tasks": ["1.3", "4.1", "9.3"] },
    { "id": 3, "tasks": ["1.4", "4.2", "4.3", "4.5"] },
    { "id": 4, "tasks": ["4.4", "4.6", "4.7", "6.1", "8.1"] },
    { "id": 5, "tasks": ["4.8", "6.2", "8.2"] },
    { "id": 6, "tasks": ["6.3", "8.3"] },
    { "id": 7, "tasks": ["6.4", "8.4"] },
    { "id": 8, "tasks": ["6.5"] },
    { "id": 9, "tasks": ["6.6"] },
    { "id": 10, "tasks": ["6.7"] }
  ]
}
```
