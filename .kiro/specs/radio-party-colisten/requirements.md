# Requirements Document

## Introduction

Black Candy Store is a fork of the self-hosted Black Candy music streaming server (Ruby on Rails). This feature adds three related social-listening capabilities on top of the existing platform: **Radio Stations**, **Party Mode**, and **Co-listen Mode**.

> An optional **AI DJ** add-on for Radio Stations and Co-listen Mode was considered for this feature but has been deliberately deferred to a separate, future specification. Nothing in this document depends on it.

The platform already provides the building blocks this feature reuses rather than reinvents:

- **Multi-library management** with a per-user Active_Library and library-scoped authorization (the existing `LibraryAccess` concern and `User#authorized_library_ids`).
- **Session and token authentication** (the existing `Authentication` concern), including a non-cookie Bearer-token path for API clients.
- **Shareable, revocable, library-scoped, optionally-expiring access tokens** (the existing `Access_Grant` model, which stores only a keyed token digest and enforces `usable?` = active and not expired).
- **A current playlist / queue** and `Playlist` model.
- **Two playback modes** — `client_cast` and `server_playback` — and an `Output_Device` model (AirPlay/Chromecast targets) driven through an out-of-process **playback sidecar** (`PlaybackSidecar`, `PlaybackController`) that owns the AirPlay/Chromecast wire protocols and exposes device dispatch behind a local `POST /play`.
- **Song streaming** via `/stream/:id` and a transcoded MP3 path.

This feature introduces three capabilities that build on the above:

1. **Radio Stations** — a User defines a station from artists, songs, and/or genres. The Server assembles a continuous, always-on MP3 stream (running independently of any listener, like a real broadcast station) that can be tuned into from the Web_Player or from any generic streaming MP3 client via a standard stream endpoint URL.
2. **Party Mode** — a host shares a link that grants Guests access to a client where they add Songs to a shared Playlist. The session is scoped to specific shared libraries only, is time-boxed (hours, days, or perpetual) and revocable, forbids Guests from changing platform/admin settings, and streams audio to host-selected Output_Devices (the existing shared-speaker mechanism).
3. **Co-listen Mode** — the combination of Radio and Party: a shared, always-on collaborative stream that multiple participants may add to, where each participant listens on their own device rather than a single shared speaker.

Two cross-cutting concerns shape every capability: an **API-first, client-agnostic** surface so a web client today and native/mobile clients later can consume the same endpoints (including Guest auth that works without cookies), and a **secure Guest/shared-access model** that reuses the existing library-scoped, revocable, time-boxed grant primitives.

### Assumptions and Risks

- **A1 (Continuous stream cost):** An always-on Radio_Station consumes server resources even with zero listeners; the number of concurrently started streams is bounded by an Admin-configurable maximum (Requirement 10).
- **A2 (Synchronization is best-effort):** Co-listen participants hear an approximately synchronized stream ("synchronized-ish"); exact sample-accurate sync across independent client devices is out of scope.
- **A3 (Generic-client stream auth):** Generic MP3 clients (Icecast/SHOUTcast players, hardware internet radios) cannot present cookies or Authorization headers. An authenticated Stream_Endpoint is therefore authorized by a URL-embedded Stream_Token; an Admin who wants credential-free access can instead mark a station public (Requirement 11).

## Glossary

- **Server**: A running Black Candy Store instance (the existing Rails application).
- **User**: An authenticated account on the Server (existing `User` model), able to create and configure stations and sessions.
- **Admin**: A User with administrative privileges (existing `User#is_admin`) who manages platform/admin settings.
- **Host**: The User who creates and owns a Party_Session or Co_Listen_Session and controls its configuration, sharing, and target devices.
- **Guest**: A participant who accesses a Party_Session or Co_Listen_Session through a Share_Link without holding a full User account, whose access is scoped, time-boxed, and revocable.
- **Library**: A named collection of music content scoped by the existing multi-library model.
- **Access_Grant**: The existing hosting-server record that authorizes a specific redeemer to reach a specific Library, stores only a keyed token digest, is revocable, and MAY carry an `expires_at` (`usable?` = active and not expired).
- **Song**: The existing `Song` model, an individual audio track belonging to exactly one Library.
- **Artist**: The existing artist entity associated with Songs.
- **Genre**: A metadata classification associated with Songs.
- **Playlist**: The existing ordered collection of Songs; a Party_Session and Co_Listen_Session each maintain a Shared_Playlist.
- **Shared_Playlist**: The collaborative, ordered collection of Songs that Guests and the Host add to within a Party_Session or Co_Listen_Session.
- **Output_Device**: The existing AirPlay or Chromecast playback target (`OutputDevice` model) reachable through the playback sidecar.
- **Playback_Sidecar**: The existing out-of-process component that owns the AirPlay/Chromecast wire protocols and to which the Server dispatches a "play this stream on these devices" intent (`PlaybackSidecar`, `PlaybackController`).
- **Radio_Station**: A User-defined configuration of source criteria (Artists, Songs, and/or Genres) from which the Server assembles a continuous audio program.
- **Station_Source_Criteria**: The set of Artists, specific Songs, and/or Genres that define which Songs are eligible for a Radio_Station's program.
- **Shared_Stream**: A continuous, always-on server-generated MP3 audio stream produced by a Radio_Station or Co_Listen_Session that plays independently of whether any Listener is connected.
- **Stream_Endpoint**: The standard HTTP MP3 streaming URL (Icecast/SHOUTcast-style) at which a Shared_Stream is exposed for tuning in by the Web_Player or any generic streaming MP3 client.
- **Listener**: A client (Web_Player or external MP3 client) currently connected to and consuming a Shared_Stream.
- **Program_Sequencer**: The Server component that selects the next Song for a Shared_Stream from the eligible Songs (or a Shared_Playlist) and orders playback.
- **Continuity_Audio**: Filler audio (such as a Station_Identification or an ambient bed) the Server emits to keep a Shared_Stream open when no eligible Song or unplayed Shared_Playlist Song is currently available.
- **Station_Identification**: A short non-music audio element (e.g., a station ident) the Server MAY insert into a Shared_Stream.
- **Party_Session**: A Host-created listening session in which Guests add Songs to a Shared_Playlist and audio plays to Host-selected Output_Devices, scoped to specific shared libraries, time-boxed, and revocable.
- **Co_Listen_Session**: A Host-created session combining a Radio-style Shared_Stream with a collaborative Shared_Playlist, where each participant listens on their own device rather than a shared Output_Device.
- **Share_Link**: A shareable URL, backed by a scoped and optionally-expiring Access_Grant, that admits a Guest to a Party_Session or Co_Listen_Session.
- **Session_Duration**: The configured lifetime of a Party_Session or Co_Listen_Session, taking a bounded value (a number of hours or days) or `perpetual` (no expiration).
- **Guest_Token**: A non-cookie Bearer credential issued to a Guest client (web or native) so Guest access works for clients that do not use cookies.
- **Stream_Visibility**: Whether a Radio_Station's Stream_Endpoint is `public` (served without credentials) or `authenticated` (requires a Stream_Token or an authorized account). Defaults to `authenticated`.
- **Stream_Token**: A scoped, revocable, optionally-expiring credential embedded in a Stream_Endpoint URL (and persisted only as a keyed digest) that authorizes a Listener whose client cannot send cookies or Authorization headers, such as a generic Icecast/SHOUTcast MP3 client.
- **Listener_Limit**: The owner- or Admin-configured maximum number of concurrent Listeners a Radio_Station or Co_Listen_Session Shared_Stream will serve.
- **Guest_Display_Name**: An optional, Guest-provided name used to attribute that Guest's Shared_Playlist additions.
- **Station_State**: A Radio_Station's lifecycle state, `started` (broadcasting a Shared_Stream) or `stopped` (not broadcasting).
- **Session_State**: A Party_Session or Co_Listen_Session's lifecycle state — `active` (running) or `ended` (deactivated by the Host, expired, or torn down).
- **API_Surface**: The client-agnostic HTTP API through which any Web_Player or future native/mobile client configures stations and sessions, joins as a Guest, and contributes to a Shared_Playlist.
- **Web_UI**: The browser-based configuration and player interface served by the Server.

## Requirements

### Requirement 1: Define a Radio Station

**User Story:** As a User, I want to define a radio station from artists, songs, and genres, so that the server can assemble a continuous program from music I choose.

#### Acceptance Criteria

1. WHEN a User submits a new Radio_Station with a name between 1 and 255 characters through the Web_UI, THE Server SHALL create a Radio_Station owned by that User.
2. THE Server SHALL allow a Radio_Station's Station_Source_Criteria to include any combination of Artists, specific Songs, and Genres.
3. IF a User submits a new Radio_Station whose Station_Source_Criteria match zero Songs the User is authorized to access, THEN THE Server SHALL reject the submission and return a validation error indicating that the criteria select no playable Songs (the update path is covered by 1.9).
4. THE Server SHALL restrict a Radio_Station's eligible Songs to Songs belonging to Libraries the owning User is authorized to access.
5. WHEN a User updates a Radio_Station's Station_Source_Criteria, THE Server SHALL recompute the set of eligible Songs from the updated criteria.
6. IF a User submits or renames a Radio_Station with a name that is empty, contains only whitespace, or exceeds 255 characters, THEN THE Server SHALL reject the request and return a validation error indicating the name length is invalid, and SHALL leave any existing Radio_Station unchanged.
7. WHEN a User deletes a Radio_Station, THE Server SHALL stop the Radio_Station's Shared_Stream and remove its configuration.
8. IF a request to create, modify, or delete a Radio_Station is made by a User who does not own that Radio_Station and is not an Admin, THEN THE Server SHALL reject the request with an authorization error.
9. IF a User updates a Radio_Station's Station_Source_Criteria such that they match zero Songs the User is authorized to access, THEN THE Server SHALL reject the update with a validation error indicating the criteria select no playable Songs, and SHALL leave the Radio_Station's existing criteria unchanged.

### Requirement 2: Generate a continuous, always-on Shared Stream

**User Story:** As a User, I want my radio station to play a continuous stream that is always running, so that it behaves like a real radio station independent of any listener.

#### Acceptance Criteria

1. WHILE a Radio_Station is started, THE Server SHALL maintain a continuous Shared_Stream that advances through Songs regardless of whether any Listener is connected.
2. WHEN one Song in a Shared_Stream finishes, THE Program_Sequencer SHALL select and play the next eligible Song without a manual request.
3. WHILE a Radio_Station is started AND its eligible Songs have all been played, THE Program_Sequencer SHALL continue the Shared_Stream by selecting further Songs from the eligible set.
4. WHEN a Listener connects to an already-running Shared_Stream, THE Server SHALL deliver the stream from the current playback position rather than from the beginning of a Song.
5. IF the Program_Sequencer cannot resolve any eligible Song at the moment a next Song is required, THEN THE Server SHALL keep the Shared_Stream open and emit Continuity_Audio until an eligible Song becomes available.
6. WHILE a Shared_Stream is running, THE Server SHALL support zero or more concurrent Listeners consuming the same stream position.

### Requirement 3: Expose the Shared Stream as a standard MP3 endpoint

**User Story:** As a Listener, I want to tune into a station from the web player or any generic MP3 client, so that I am not limited to an in-app-only feature.

#### Acceptance Criteria

1. WHILE a Radio_Station is started, THE Server SHALL expose its Shared_Stream at a Stream_Endpoint as a continuous MP3 stream.
2. WHEN a generic streaming MP3 client requests a started Radio_Station's Stream_Endpoint with credentials appropriate to the station's Stream_Visibility (per Requirement 11), THE Server SHALL respond with a continuous MP3 audio stream consumable by that client.
3. WHEN the Web_Player requests a started Radio_Station's Stream_Endpoint, THE Server SHALL deliver the same continuous MP3 stream delivered to external clients.
4. THE Server SHALL enforce a Radio_Station's configured Stream_Visibility when serving its Stream_Endpoint, as specified in Requirement 11 (public vs authenticated).
5. IF a Radio_Station's Stream_Visibility is `authenticated` AND a Stream_Endpoint request presents neither a valid Stream_Token nor a valid authorized account credential, THEN THE Server SHALL reject the request with an authentication error and SHALL NOT deliver audio.
6. IF a request targets a Stream_Endpoint for a Radio_Station that is not started, THEN THE Server SHALL return a not-available response indicating the station is not broadcasting.
7. WHERE a Radio_Station's Stream_Visibility is `public`, THE Server SHALL serve its Stream_Endpoint to any client without requiring credentials.

### Requirement 4: Create and configure a Party Session

**User Story:** As a Host, I want to create a party session and share a link, so that guests can join and add songs to a shared playlist.

#### Acceptance Criteria

1. WHEN a Host creates a Party_Session through the Web_UI, THE Server SHALL create a Party_Session that owns a Shared_Playlist and is associated with the Host.
2. WHEN a Host requests a Share_Link for a Party_Session, THE Server SHALL generate a Share_Link backed by an Access_Grant scoped to that Party_Session.
3. THE Server SHALL allow a Host to configure a Party_Session's Session_Duration as a number of hours, a number of days, or `perpetual`.
4. WHERE a Party_Session's Session_Duration is a number of hours or days, THE Server SHALL set the backing Access_Grant's `expires_at` to the corresponding future time.
5. WHERE a Party_Session's Session_Duration is `perpetual`, THE Server SHALL create the backing Access_Grant with no expiration.
6. WHEN a Host revokes a Party_Session, THE Server SHALL revoke the backing Access_Grant so that no further Guest may join, while already-admitted Guests retain access until the Party_Session ends or they leave.
7. THE Server SHALL allow a Host to select which Libraries a Party_Session shares from among the Libraries the Host is authorized to access.

### Requirement 5: Guest access to a Party Session

**User Story:** As a Guest, I want to open a share link and add songs to the party, so that I can contribute without needing a platform account or admin rights.

#### Acceptance Criteria

1. WHEN a Guest opens a valid Share_Link for a Party_Session whose backing Access_Grant is usable, THE Server SHALL admit the Guest to that Party_Session and issue a Guest_Token.
2. WHEN an admitted Guest adds a Song that belongs to a shared Library to the Party_Session, THE Server SHALL append that Song to the Shared_Playlist.
3. THE Server SHALL restrict a Guest's readable and addable Songs to Songs belonging to the Libraries the Party_Session is configured to share.
4. IF a Guest requests a Song or Library that the Party_Session does not share, THEN THE Server SHALL return a not-found response that does not reveal whether that content exists.
5. IF a Guest attempts to change any platform setting, admin setting, or another User's data, THEN THE Server SHALL reject the request with an authorization error.
6. IF a Guest presents a Guest_Token after the Party_Session has expired, after the Guest has been removed, or after the Party_Session has ended, THEN THE Server SHALL reject the request with an authorization error.
7. THE Server SHALL limit a Guest to streaming individual Songs and adding individual Songs to the Shared_Playlist, and SHALL NOT expose to a Guest any download, export, bulk-fetch, or file-path endpoint for a shared Library.
8. WHEN the Host removes a Guest from a Party_Session, THE Server SHALL reject that Guest's subsequent requests with an authorization error.
9. THE Server SHALL enforce a configurable per-Guest add quota and add rate for a Party_Session, and IF a Guest exceeds that quota or rate THEN THE Server SHALL reject the excess additions with a rate-limit error and leave the Shared_Playlist unchanged for those rejected additions.
10. IF a Guest adds a Song already present in the Shared_Playlist, THEN THE Server SHALL apply the Party_Session's configured duplicate policy (reject the duplicate or allow it) and, when rejecting, SHALL leave the Shared_Playlist unchanged.
11. THE Server SHALL enforce a configurable maximum number of concurrent Guests per Party_Session and SHALL refuse admission beyond that maximum with a capacity response.
12. THE Server SHALL allow a Guest to provide an optional Guest_Display_Name and SHALL attribute each Shared_Playlist addition to the Guest that added it.
13. THE Server SHALL identify each admitted Guest by a distinct Guest record bound to the Guest_Token issued at admission, and SHALL treat every request bearing that Guest_Token as the same Guest when enforcing playlist-removal permissions (6.6) and per-Guest add quotas (5.9).

### Requirement 6: Party Session playback to shared devices

**User Story:** As a Host, I want the party to play to speakers I choose, so that everyone in the room hears the shared playlist together.

#### Acceptance Criteria

1. WHEN a Host selects one or more Output_Devices for a Party_Session, THE Server SHALL dispatch the Party_Session's audio to those Output_Devices through the Playback_Sidecar.
2. THE Server SHALL restrict selection of Output_Devices for a Party_Session to the Host.
3. WHEN a Song is added to or removed from a Party_Session's Shared_Playlist, THE Server SHALL play the Shared_Playlist in its current order on the selected Output_Devices.
4. IF a selected Output_Device becomes unavailable during a Party_Session, THEN THE Server SHALL continue playback on the remaining selected Output_Devices, and IF no selected Output_Device remains available THEN THE Server SHALL stop playback for that Party_Session.
5. IF a Guest attempts to select or change a Party_Session's Output_Devices, THEN THE Server SHALL reject the request with an authorization error.
6. THE Server SHALL allow the Host to remove or reorder any Song in a Party_Session's Shared_Playlist, SHALL allow a Guest to remove only Songs that same Guest added, and SHALL reject a Guest's attempt to remove or reorder another participant's Song with an authorization error.
7. WHEN a Party_Session's Shared_Playlist reaches its end, THE Server SHALL loop the Shared_Playlist from the beginning and continue playback without interruption.
8. THE Server SHALL restrict transport control of a Party_Session's playback (stop, pause, and skip) to the Host, and IF a Guest attempts to stop, pause, or skip playback THEN THE Server SHALL reject the request with an authorization error.

### Requirement 7: Co-listen Mode

**User Story:** As a Host, I want a shared continuous stream that everyone can add to but each person hears on their own device, so that we can listen together while apart.

#### Acceptance Criteria

1. WHEN a Host creates a Co_Listen_Session through the Web_UI, THE Server SHALL create a Co_Listen_Session that owns a Shared_Playlist and produces a Shared_Stream.
2. WHILE a Co_Listen_Session is active, THE Server SHALL maintain a continuous Shared_Stream that advances through the Shared_Playlist independently of any single participant.
3. WHEN an admitted participant adds a Song that belongs to a shared Library to a Co_Listen_Session, THE Server SHALL append that Song to the Shared_Playlist.
4. WHEN a participant tunes into a Co_Listen_Session's Shared_Stream, THE Server SHALL deliver the stream to that participant's own device from the current playback position.
5. THE Server SHALL deliver a Co_Listen_Session's Shared_Stream to each participant on that participant's own device rather than to a single shared Output_Device.
6. WHEN a participant connects to a Co_Listen_Session's Shared_Stream, THE Server SHALL start that participant at the Shared_Stream's current playback position (per 7.4) so that participants connecting at the same time hear approximately the same audio; exact sample-accurate cross-device synchronization is out of scope (Assumption A2).
7. THE Server SHALL apply the same Guest sharing, library scoping, time-boxing, and revocation rules to a Co_Listen_Session that apply to a Party_Session.
8. WHILE a Co_Listen_Session is active AND every Song in its Shared_Playlist has been played, THE Server SHALL loop the Shared_Playlist from the beginning and continue playback without interruption.
9. IF a Co_Listen_Session's Shared_Playlist is empty (no Song has ever been added), THEN THE Server SHALL keep the Shared_Stream open and emit Continuity_Audio until a participant adds a Song, then begin playback with that Song.
10. THE Server SHALL restrict transport control of a Co_Listen_Session's Shared_Stream (stop, pause, and skip) to the Host, and IF a Guest attempts to stop, pause, or skip the Shared_Stream THEN THE Server SHALL reject the request with an authorization error.

### Requirement 8: Shared guest access model

**User Story:** As a Host, I want shareable links that are scoped, time-boxed, and revocable, so that I can invite people safely without exposing my whole library or my settings.

#### Acceptance Criteria

1. THE Server SHALL back every Share_Link with an Access_Grant that is scoped to specific Libraries and MAY carry an expiration.
2. THE Server SHALL scope a Guest's access to only the Libraries the associated Party_Session or Co_Listen_Session is configured to share.
3. THE Server SHALL support a Session_Duration expressed as a number of hours, a number of days, or `perpetual` for every shared session.
4. WHEN a Session_Duration's corresponding expiration time passes, THE Server SHALL treat the shared session as expired and reject every Guest request, including requests from already-admitted Guests, with an authorization error.
5. WHEN a Host revokes a shared session, THE Server SHALL revoke the backing Access_Grant so that no further Guest may join, revocation SHALL be terminal, and already-admitted Guests SHALL retain access until the session expires or ends.
6. THE Server SHALL prevent a Guest from accessing any Library, User data, platform setting, or admin setting outside the scope granted by the shared session.
7. THE Server SHALL store Share_Link credentials as keyed digests and SHALL NOT persist the plaintext token.

### Requirement 9: API-first, multi-client access

**User Story:** As a developer, I want a clean client-agnostic API, so that a web client today and native or mobile clients later can use the same features.

#### Acceptance Criteria

1. THE Server SHALL expose Radio_Station configuration, Party_Session and Co_Listen_Session management, Guest join, and Shared_Playlist contribution through an API_Surface consumable by both the Web_Player and a native or mobile client.
2. THE Server SHALL authenticate Guest API requests using a Guest_Token presented as a non-cookie Bearer credential.
3. THE Server SHALL authenticate full-account API requests using the existing session cookie or Bearer token mechanism.
4. THE Server SHALL return Radio_Station, Party_Session, and Co_Listen_Session state through the API_Surface in a client-agnostic representation that does not depend on server-rendered HTML.
5. THE Server SHALL apply the same authorization rules to an API_Surface request that it applies to the equivalent Web_UI request.
6. THE Server SHALL expose a Stream_Endpoint URL for every existing Radio_Station and Co_Listen_Session regardless of its started or active state, while delivering audio at that Stream_Endpoint only while the Radio_Station is started or the Co_Listen_Session is active (per Requirements 3.2 and 3.6).
7. THE Server SHALL NOT expose a Stream_Endpoint for a Party_Session, because a Party_Session plays to selected Output_Devices rather than to per-Listener streams.

### Requirement 10: Station and session lifecycle, persistence, and concurrency

**User Story:** As a User or Host, I want to start and stop my radio station or co-listen session and have started ones survive server restarts within a resource limit, so that they behave like dependable broadcasts without exhausting the server.

#### Acceptance Criteria

1. WHEN the owning User or an Admin starts a Radio_Station, THE Server SHALL transition it to `started` and begin its Shared_Stream.
2. WHEN the owning User or an Admin stops a Radio_Station, THE Server SHALL transition it to `stopped`, end its Shared_Stream, and stop serving audio at its Stream_Endpoint.
3. IF a User who is neither the owner nor an Admin attempts to start or stop a Radio_Station, THEN THE Server SHALL reject the request with an authorization error.
4. WHEN the Server restarts, THE Server SHALL resume every Radio_Station that was `started` before the restart, subject to the concurrency limit in 10.5.
5. THE Server SHALL enforce an Admin-configurable maximum number of concurrently `started` Radio_Station and Co_Listen_Session Shared_Streams.
6. IF starting a Radio_Station or activating a Co_Listen_Session would exceed the maximum number of concurrent Shared_Streams, THEN THE Server SHALL reject the start request with a capacity error and leave the Radio_Station `stopped` or the Co_Listen_Session inactive.
7. WHEN the Host activates a Co_Listen_Session, THE Server SHALL transition it to `active` and begin its Shared_Stream, subject to the concurrency limit in 10.5.
8. WHEN the Host deactivates or ends a Co_Listen_Session, THE Server SHALL transition it to `ended` and end its Shared_Stream, with teardown per Requirement 12.
9. IF a User who is neither the Host nor an Admin attempts to activate or deactivate a Co_Listen_Session, THEN THE Server SHALL reject the request with an authorization error.
10. WHEN the Server restarts, THE Server SHALL resume every Co_Listen_Session that was `active` and whose Session_Duration has not expired, subject to the concurrency limit in 10.5.

### Requirement 11: Stream access control and listener limits

**User Story:** As an Admin, I want to choose whether a station's stream is public or requires authentication and cap how many listeners it serves, so that generic clients can tune in when I allow it while I stay in control of access and load.

#### Acceptance Criteria

1. THE Server SHALL allow the owning User or an Admin to configure a Radio_Station's Stream_Visibility as `public` or `authenticated`, defaulting to `authenticated`.
2. WHERE a Radio_Station's Stream_Visibility is `public`, THE Server SHALL serve its Stream_Endpoint to any client without requiring credentials.
3. WHERE a Radio_Station's Stream_Visibility is `authenticated`, THE Server SHALL authorize a Stream_Endpoint request that presents a valid Stream_Token embedded in the Stream_Endpoint URL, so that a generic MP3 client that cannot send cookies or Authorization headers can still tune in.
4. WHERE a Radio_Station's Stream_Visibility is `authenticated`, THE Server SHALL also authorize a Stream_Endpoint request that presents a valid session cookie or Bearer token for an account authorized to access the Radio_Station.
5. THE Server SHALL persist a Stream_Token only as a keyed digest, SHALL NOT persist its plaintext, and SHALL allow the owning User or an Admin to rotate or revoke it; a rotated or revoked Stream_Token SHALL no longer authorize access.
6. THE Server SHALL allow the owning User or an Admin to configure a Listener_Limit (maximum concurrent Listeners) for a Radio_Station or Co_Listen_Session.
7. IF a new Listener connects to a Shared_Stream that has reached its configured Listener_Limit, THEN THE Server SHALL refuse the new connection with a capacity response and SHALL NOT disrupt existing Listeners.
8. THE Server SHALL authorize a Co_Listen_Session's Stream_Endpoint with a guest-scoped Stream_Token embedded in the Stream_Endpoint URL (derived from the participant's Guest_Token), so that a generic MP3 client that cannot send cookies or Authorization headers can tune into a Co_Listen_Session the participant has joined; a Co_Listen_Session Shared_Stream SHALL NOT be `public`.
9. THE Server SHALL scope a Co_Listen_Session Stream_Token to that session and its shared Libraries, and SHALL invalidate it when the participant's access ends through session expiry, revocation, Guest removal, or session teardown.

### Requirement 12: Shared session teardown

**User Story:** As a Host, I want a party or co-listen session to clean up when it ends, so that playback stops and guests can no longer reach my libraries.

#### Acceptance Criteria

1. WHEN a Party_Session or Co_Listen_Session ends or its Session_Duration expires, THE Server SHALL stop the session's Shared_Stream and any playback it dispatched to Output_Devices.
2. WHEN a Party_Session or Co_Listen_Session ends or expires, THE Server SHALL reject every subsequent Guest request for that session with an authorization error.
3. WHEN a Party_Session or Co_Listen_Session ends or expires, THE Server SHALL retain its Shared_Playlist for the Host to review and SHALL make it inaccessible to Guests.
4. WHEN the Server restarts, THE Server SHALL treat any Party_Session or Co_Listen_Session whose Session_Duration has expired as ended.
