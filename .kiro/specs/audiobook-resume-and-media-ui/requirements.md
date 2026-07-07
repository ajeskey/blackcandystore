# Requirements Document

## Introduction

Black Candy Store is a fork of the self-hosted Black Candy music streaming server (Ruby on Rails, ERB + Hotwire/Turbo/Stimulus). This feature specifies two related, user-facing capabilities that build on the existing platform:

1. **Playback-position resume ("remember where the listener left off").** Today the platform does not persist elapsed playback position. The browser player (`app/javascript/player.js` and `player_controller.js`) can `seek()` within a single session, but position resets on stop or page reload, and the schema's existing `position` columns are unrelated to elapsed time (`playback_sessions.position` / `cast_sessions.position` hold a playlist index; `playlists_songs.position` / `shared_playlist_entries.position` hold ordering). This feature adds a per-User, per-Song elapsed-position store, an auto-resume behavior when a Resumable_Track is reopened, and a "Continue listening" surface. Position is written to the browser immediately for responsiveness and synchronized to the Server as the source of truth, so resume works across a User's devices.

2. **Navigation entry points for existing but unsurfaced sections.** Radio Stations, Party Sessions, and Co-listen Sessions already have full controllers, routes, and views (from the `radio-party-colisten` spec) but are not reachable from the global navigation. The nav bar (`app/views/shared/_nav_bar.html.erb`) currently exposes only Home and Library, and the account menu (`app/views/shared/_account_menu.html.erb`) exposes account-level items. This feature adds discoverable top-level navigation tabs for those three sections.

The platform already provides building blocks this feature reuses rather than reinvents:

- **Content classification** — `ContentClassifier` tags an Album as `:audiobook`, `:live`, or `:music` from its tags, and `Album#audiobook?` / `Album#enriched?` already drive an audiobook badge and Open Library metadata on `app/views/albums/show.html.erb`.
- **Authentication and per-user scoping** — the `Authentication` concern establishes `Current.session` / `Current.user` from a signed cookie or a Bearer token, and per-user preferences are persisted through the `has_setting` mechanism (`ScopedSettingConcern`) and dedicated per-user columns.
- **Library-scoped authorization** — `User#authorized_library_ids` and the `LibraryAccess` concern bound what content a User may read or stream.
- **A client-agnostic surface** — controllers answer both Turbo HTML and JSON so a web client today and native/mobile clients later consume the same endpoints.
- **The existing Web_Player** — a Stimulus `player_controller` wrapping a Howler-based `Player`, already tracking `currentTime`, dispatching `player:playing` / `player:pause` / `player:stop` / `player:end` events, and persisting volume to `localStorage`.

### Assumptions and Risks

- **A1 (Resumable scope):** Position resume applies to Resumable_Tracks — Songs belonging to an audiobook Album (`ContentClassifier` = `:audiobook`) and any Song whose duration is at least the Long_Track_Threshold. Ordinary short music tracks are intentionally out of scope to avoid cluttering the Continue_Listening_List.
- **A2 (Long_Track_Threshold value):** The Long_Track_Threshold is fixed at 1200 seconds (20 minutes). This is a chosen default, not a User-configurable setting in this feature.
- **A3 (Source of truth):** The Server holds the authoritative Playback_Position. The Web_Player also writes to `localStorage` for instant local response; on load it reconciles the two by preferring the record with the most recent update time (Requirement 6).
- **A4 (Best-effort saving):** Position saving to the Server is best-effort and network-dependent. A failed save must not interrupt playback; the locally stored position remains and is retried or reconciled on the next opportunity.
- **A5 (Navigation scope):** This feature only adds navigation entry points to the already-implemented Radio Stations, Party Sessions, and Co-listen Sessions pages. It does not modify those pages' behavior or authorization.

## Glossary

- **Server**: A running Black Candy Store instance (the existing Rails application).
- **User**: An authenticated account on the Server (existing `User` model).
- **Web_Player**: The browser-based player served by the Server (the existing Stimulus `player_controller` and Howler-based `Player`).
- **App_Player**: A native or mobile client that consumes the same client-agnostic API as the Web_Player.
- **Client**: The Web_Player or an App_Player acting on behalf of a User.
- **Song**: The existing `Song` model, an individual audio track with a `duration` in seconds, belonging to exactly one Library and Album.
- **Album**: The existing `Album` model, a collection of Songs, classifiable by `ContentClassifier` as `:audiobook`, `:live`, or `:music`.
- **Audiobook**: An Album whose `ContentClassifier` content type is `:audiobook`.
- **Library**: A named collection of content scoped by the existing multi-library model; access is bounded by `User#authorized_library_ids`.
- **Long_Track_Threshold**: The minimum Song duration, 1200 seconds, at or above which a Song qualifies as a Resumable_Track regardless of content type (Assumption A2).
- **Resumable_Track**: A Song that is eligible for playback-position resume — a Song belonging to an Audiobook, or any Song whose duration is at least the Long_Track_Threshold.
- **Playback_Position**: The elapsed play time, in seconds, from the start of a Song.
- **Playback_Position_Record**: The Server-persisted record of a User's Playback_Position for a single Resumable_Track, identified by the pair (User, Song), storing the elapsed position in seconds, a last-updated timestamp, and a finished indicator.
- **Minimum_Resume_Position**: The smallest Playback_Position, 10 seconds, at or above which a saved position is treated as a meaningful resume point rather than a negligible start.
- **Finished_Threshold**: The point near the end of a Song, defined as a remaining time of 30 seconds or less, at or beyond which the Song is treated as finished.
- **Save_Interval**: The maximum elapsed play time, 10 seconds, between successive Server saves of a Playback_Position while a Resumable_Track is playing.
- **Continue_Listening_List**: The ordered collection of a User's in-progress Resumable_Tracks (those with a saved Playback_Position at or above the Minimum_Resume_Position and not finished), presented so the User can resume them.
- **Local_Position_Store**: The browser-side store (`localStorage`) in which the Web_Player records Playback_Position immediately for responsiveness.
- **Global_Navigation**: The site-wide navigation tab bar rendered by `app/views/shared/_nav_bar.html.erb`.
- **Radio_Stations_Section**: The existing Radio Stations pages, controller, and routes (`radio_stations`).
- **Party_Sessions_Section**: The existing Party Sessions pages, controller, and routes (`party_sessions`).
- **Co_Listen_Sessions_Section**: The existing Co-listen Sessions pages, controller, and routes (`co_listen_sessions`).

## Requirements

### Requirement 1: Identify resumable content

**User Story:** As a listener, I want the platform to know which items are long-form, so that position-resume only applies where it is useful.

#### Acceptance Criteria

1. WHERE a Song belongs to an Audiobook, THE Server SHALL classify the Song as a Resumable_Track.
2. WHERE a Song's duration is at least the Long_Track_Threshold, THE Server SHALL classify the Song as a Resumable_Track.
3. WHERE a Song is neither part of an Audiobook nor at least the Long_Track_Threshold in duration, THE Server SHALL treat the Song as not resumable and SHALL NOT retain a Playback_Position_Record for it.
4. THE Server SHALL determine a Song's Audiobook status from the existing `ContentClassifier` content type rather than from a separately maintained flag.

### Requirement 2: Capture and persist playback position

**User Story:** As a listener, I want my elapsed position saved as I listen, so that I can return to the same spot later.

#### Acceptance Criteria

1. WHILE a Resumable_Track is playing in the Web_Player, THE Web_Player SHALL record the current Playback_Position to the Local_Position_Store at least once every Save_Interval.
2. WHILE a Resumable_Track is playing in the Web_Player, THE Web_Player SHALL send the current Playback_Position to the Server at least once every Save_Interval.
3. WHEN a listener pauses, stops, seeks within, or navigates away from a playing Resumable_Track, THE Web_Player SHALL record the current Playback_Position to the Local_Position_Store and send it to the Server.
4. WHEN the Server receives a Playback_Position for a User and a Resumable_Track, THE Server SHALL store it as the Playback_Position_Record for that (User, Song) pair with the time of the update.
5. WHEN the Server receives a subsequent Playback_Position for a (User, Song) pair that already has a Playback_Position_Record, THE Server SHALL replace the stored position and update the record's last-updated timestamp.
6. IF a Client sends a Playback_Position that is negative or greater than the Song's duration, THEN THE Server SHALL reject the request with a validation error and SHALL leave any existing Playback_Position_Record unchanged.
7. IF a Client sends a Playback_Position for a Song that is not a Resumable_Track, THEN THE Server SHALL reject the request with a validation error and SHALL NOT create a Playback_Position_Record.
8. IF a save of a Playback_Position to the Server fails, THEN THE Web_Player SHALL continue playback without interruption and SHALL retain the Playback_Position in the Local_Position_Store for a later save or reconciliation.

### Requirement 3: Resume position when reopening a track

**User Story:** As a listener, I want playback to continue from where I left off, so that I do not have to find my place manually.

#### Acceptance Criteria

1. WHEN a listener starts playback of a Resumable_Track that has a stored Playback_Position at or above the Minimum_Resume_Position and below the Finished_Threshold, THE Web_Player SHALL begin playback from the stored Playback_Position.
2. WHEN a listener starts playback of a Resumable_Track that has no stored Playback_Position, THE Web_Player SHALL begin playback from the start of the Song.
3. WHERE a Resumable_Track's stored Playback_Position is below the Minimum_Resume_Position, THE Web_Player SHALL begin playback from the start of the Song.
4. WHERE a Resumable_Track has been marked finished, THE Web_Player SHALL begin playback from the start of the Song.
5. THE Web_Player SHALL provide a control that starts playback of a Resumable_Track from the beginning regardless of any stored Playback_Position.
6. WHEN the Web_Player resumes a Resumable_Track from a stored Playback_Position, THE Web_Player SHALL reflect the resumed position in both the player's progress bar and its elapsed-time display, which MAY update independently provided both eventually reflect the resumed position.

### Requirement 4: Continue listening surface

**User Story:** As a listener, I want a list of things I have started but not finished, so that I can pick one and keep going.

#### Acceptance Criteria

1. THE Server SHALL provide a Continue_Listening_List for the current User containing each Resumable_Track that has a Playback_Position_Record at or above the Minimum_Resume_Position and is not marked finished.
2. THE Server SHALL order the Continue_Listening_List by each Playback_Position_Record's last-updated time, most recent first.
3. THE Server SHALL exclude from the Continue_Listening_List every Resumable_Track that is marked finished.
4. THE Server SHALL exclude from the Continue_Listening_List every Resumable_Track that belongs to a Library the current User is not authorized to access.
5. WHEN a listener selects an item from the Continue_Listening_List, THE Web_Player SHALL begin playback of that Resumable_Track from its stored Playback_Position.
6. THE Server SHALL limit the Continue_Listening_List to at most 20 Resumable_Tracks.
7. WHERE the current User has no in-progress Resumable_Track, THE Server SHALL present an empty Continue_Listening_List without error.

### Requirement 5: Marking a track finished

**User Story:** As a listener, I want an item to drop off my continue-listening list once I finish it, so that the list stays relevant.

#### Acceptance Criteria

1. WHEN a Resumable_Track's Playback_Position reaches a remaining time at or below the Finished_Threshold, THE Server SHALL mark that (User, Song) Playback_Position_Record finished.
2. WHEN a Resumable_Track plays to its end in the Web_Player, THE Web_Player SHALL send a finished indication to the Server for that Resumable_Track.
3. WHEN a Playback_Position_Record is marked finished, THE Server SHALL exclude the corresponding Resumable_Track from the Continue_Listening_List.
4. WHEN a listener restarts a finished Resumable_Track from the beginning and plays past the Minimum_Resume_Position, THE Server SHALL clear the finished indicator and again treat the Resumable_Track as in progress.
5. IF the Web_Player does not send a finished indication (for example due to a network failure or crash), THEN THE Server SHALL still mark a Playback_Position_Record finished when the most recently saved Playback_Position has reached a remaining time at or below the Finished_Threshold, so a missed client signal does not leave a completed Resumable_Track in progress.

### Requirement 6: Cross-device position and reconciliation

**User Story:** As a listener, I want my position to follow me between devices, so that I can start on one device and continue on another.

#### Acceptance Criteria

1. THE Server SHALL store each Playback_Position_Record per User so that a User's position for a Resumable_Track is available to any Client that authenticates as that User.
2. WHEN a Client requests a User's stored Playback_Position for a Resumable_Track, THE Server SHALL return the authoritative Playback_Position_Record for that (User, Song) pair.
3. WHEN the Web_Player loads a Resumable_Track and both a Local_Position_Store value and a Server Playback_Position_Record exist, THE Web_Player SHALL use the position whose last-updated time is more recent.
4. WHEN the Web_Player loads a Resumable_Track for which only a Local_Position_Store value exists, THE Web_Player SHALL send that value to the Server so the Server becomes consistent with it.
5. WHERE the Server-held Playback_Position_Record's last-updated time is more recent than a value presented by a Client, THE Server SHALL treat the Server-held Playback_Position_Record as the source of truth.

### Requirement 7: Authorization and scoping of position data

**User Story:** As a User, I want my listening position to be private to me, so that other accounts cannot read or change it.

#### Acceptance Criteria

1. THE Server SHALL associate every Playback_Position_Record with the authenticated User that produced it.
2. IF a request to read or write a Playback_Position is made without an authenticated session or valid token, THEN THE Server SHALL reject the request with an authentication error.
3. THE Server SHALL restrict a read of Playback_Position data to the Playback_Position_Records owned by the authenticated User.
4. IF a Client attempts to read or modify another User's Playback_Position_Record, THEN THE Server SHALL reject the request with an authorization error.
5. WHEN a User is deleted, THE Server SHALL delete that User's Playback_Position_Records.
6. THE Server SHALL authenticate a Playback_Position request using the existing session cookie or Bearer token mechanism.
7. IF the Server cannot determine the owning User of a Playback_Position_Record (for example due to missing or corrupted ownership metadata), THEN THE Server SHALL reject the request with an authorization error and SHALL NOT read or modify the record.

### Requirement 8: Client-agnostic position API

**User Story:** As a developer, I want a clean position API, so that the Web_Player today and native clients later can save and resume positions the same way.

#### Acceptance Criteria

1. THE Server SHALL expose reading and writing of a User's Playback_Position through an API consumable by both the Web_Player and an App_Player.
2. THE Server SHALL return Playback_Position and Continue_Listening_List data in a client-agnostic representation that does not depend on server-rendered HTML.
3. THE Server SHALL apply the same authorization rules to a Playback_Position API request that it applies to the equivalent Web_Player request.

### Requirement 9: Navigation entry points for social-listening sections

**User Story:** As a User, I want to reach Radio Stations, Party Sessions, and Co-listen Sessions from the main navigation, so that I can discover and use features that already exist.

#### Acceptance Criteria

1. THE Global_Navigation SHALL present a top-level tab that links to the Radio_Stations_Section.
2. THE Global_Navigation SHALL present a top-level tab that links to the Party_Sessions_Section.
3. THE Global_Navigation SHALL present a top-level tab that links to the Co_Listen_Sessions_Section.
4. WHILE a User is viewing a page within the Radio_Stations_Section, THE Global_Navigation SHALL indicate the Radio Stations tab as the active tab.
5. WHILE a User is viewing a page within the Party_Sessions_Section, THE Global_Navigation SHALL indicate the Party Sessions tab as the active tab.
6. WHILE a User is viewing a page within the Co_Listen_Sessions_Section, THE Global_Navigation SHALL indicate the Co-listen Sessions tab as the active tab.
7. WHEN a User activates a social-listening navigation tab, THE Server SHALL apply the same authorization rules to the resulting request that already govern the target section.
8. THE Global_Navigation SHALL continue to present the existing Home and Library tabs alongside the added tabs.
9. WHILE a User is not viewing any of the Radio_Stations_Section, Party_Sessions_Section, or Co_Listen_Sessions_Section, THE Global_Navigation SHALL indicate none of those three tabs as active.
10. WHERE a page belongs to more than one navigable section, THE Global_Navigation MAY indicate more than one tab as active simultaneously; it SHALL NOT force exactly one of the three social-listening tabs to be active.

### Requirement 10: Surfacing continue-listening in the interface

**User Story:** As a listener, I want the continue-listening items visible in the app, so that resuming is one click away.

#### Acceptance Criteria

1. THE Server SHALL present the current User's Continue_Listening_List on the Home page.
2. THE Server SHALL show, for each Continue_Listening_List item, the Song name, its Album name, and enough identifying detail for the User to recognize the item.
3. WHERE an item in the Continue_Listening_List belongs to an Audiobook that has stored enrichment, THE Server SHALL display the audiobook context already available for that Album (such as author) consistent with the existing album-page enrichment display.
4. WHERE the current User has no in-progress Resumable_Track, THE Server SHALL present the Continue_Listening surface in an empty state showing a message indicating there are no items to resume, without error.
