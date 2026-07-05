# Requirements Document

## Introduction

Black Candy Store is a fork of the self-hosted Black Candy music streaming server (Ruby on Rails). The existing **multi-server-library-sharing** feature lets a User on one Server redeem an Invite_Code for a Library hosted on another Server, establishing a persistent Library_Connection (holding `server_base_url`, `remote_library_id`, an encrypted grant token, and a status) plus a shell remote Library row. Today the redeeming Server stores **no catalog** for that Remote_Library — browsing was intended to be served live through the Federation API, but that last-mile wiring is incomplete, so browsing into a Remote_Library currently returns nothing.

This feature adds a **materialized catalog mirror with hybrid synchronization**. For browsing speed, each hosting Server propagates its Library's catalog metadata to the Servers it has shared that Library with, so a redeeming Server keeps a **local mirror (index)** of the Remote_Library's songs, albums, and artists and browses it with fast local queries instead of a live round-trip per request.

Two decisions shape the whole feature:

1. **The mirror is metadata only.** The redeeming Server materializes the Remote_Library's songs/albums/artists (names, durations, track/disc numbers, album/artist associations, and the stable hosting-side identifiers) as local rows associated with the remote Library. Actual audio bytes and artwork bytes are **not** stored — playback and artwork continue to stream and proxy **live** at request time through the existing Federation API and the existing remote-stream proxy. The mirror only provides the browsable index and the hosting-side identifier needed to stream.

2. **Synchronization is hybrid: a pull backbone with a best-effort push nudge.** A full initial sync runs when a Library_Connection is first established. Thereafter the redeeming Server periodically pulls "changes since a cursor" from the hosting Server; additions, metadata updates, and deletions on the host all propagate to the mirror. The hosting Server additionally sends a best-effort "catalog changed" nudge to redeemers with active grants so they pull immediately; because a redeemer may be unreachable behind NAT, the nudge is only an optimization and the next scheduled pull always reconciles — correctness never depends on nudge delivery.

This feature builds on and reuses the terminology and components of the multi-server-library-sharing spec (Library_Connection, Access_Grant, Federation API, Remote_Library, hosting/redeeming Server, Path_Resolver, Source_Preference, Deduplicator, Authorized_Content, DAAP_Service, RSP_Service). It stays consistent with the existing rule that DAAP/RSP Media_Clients serve only local, authorized content, and that a remote copy is available only while its Library_Connection is active.

## Glossary

Terms reused from the multi-server-library-sharing specification (unchanged meaning):

- **Server**: A running Black Candy Store instance identified by a stable public base URL.
- **Hosting_Server**: The Server that owns a Local_Library and shares it; it exposes the Federation API and holds the Access_Grants.
- **Redeeming_Server**: The Server that has redeemed an Invite_Code for a Remote_Library and holds the Library_Connection.
- **User**: An authenticated account on a Server.
- **Library**: A named collection of music content (songs, albums, artists).
- **Local_Library**: A Library whose content and media files are hosted on the current Server.
- **Remote_Library**: A Library hosted on another Server made accessible to the current Server through a redeemed Invite_Code, reached through a Library_Connection.
- **Library_Connection**: The record on the Redeeming_Server that stores how to reach and authenticate against a Remote_Library (`server_base_url`, `remote_library_id`, encrypted `grant_token`, `user_id`, and a status of `active`, `revoked`, or `unavailable`).
- **Access_Grant**: The record on the Hosting_Server that authorizes a specific redeemer to access a specific Local_Library and that can be revoked or can expire.
- **Federation API**: The token-authorized cross-server HTTP API under the `/federation` namespace on the Hosting_Server, authenticated by the Access_Grant token presented as `Authorization: Bearer <grant_token>`.
- **Federation_Client**: The Redeeming_Server component (`Federation::Client`) that makes Federation API calls for a Library_Connection, applying explicit timeout budgets and translating transport/HTTP failures into domain errors.
- **Path_Resolver**: The Redeeming_Server component that classifies a Song's Stream_Source and produces its Resolved_Stream_Path, and the analogous asset resolution.
- **Source_Preference**: A per-User setting (`prefer_own_server` or `prefer_highest_quality`) selecting which source to resolve when the same content is available from more than one accessible source.
- **Deduplicator**: The component that groups Songs across Libraries and Servers that represent the same underlying content.
- **Authorized_Content**: For a connecting Media_Client, the set of Songs, Albums, and Artists belonging to the Local_Libraries the authenticated account is authorized to access.
- **Media_Client**: An external DAAP or RSP client that connects to the Server to browse and download-and-play content.
- **DAAP_Service / RSP_Service**: The Server components that expose Authorized_Content (local only) to Media_Clients.

Terms introduced by this feature:

- **Catalog**: The complete set of songs, albums, and artists belonging to one Local_Library on a Hosting_Server at a point in time, described by metadata only (names, durations, track/disc numbers, album/artist associations, and stable hosting-side identifiers).
- **Catalog_Mirror**: The metadata-only materialization of a Remote_Library's Catalog stored on the Redeeming_Server as local song/album/artist rows associated with that Remote_Library. The Catalog_Mirror contains no audio bytes and no artwork bytes.
- **Mirrored_Song / Mirrored_Album / Mirrored_Artist**: A song, album, or artist row within a Catalog_Mirror. A Mirrored_Song carries the hosting-side song identifier (its Remote_Song_Id) so the existing remote-stream proxy can fetch its audio.
- **Remote_Song_Id** (and **Remote_Album_Id**, **Remote_Artist_Id**): The stable identifier a content item has on the Hosting_Server, stored on the corresponding mirrored row so the Redeeming_Server can reference the hosting item for streaming, artwork proxying, and incremental reconciliation.
- **Catalog_Version** (**Sync_Cursor**): A monotonically non-decreasing value maintained by the Hosting_Server for a Local_Library that increases whenever the Library's Catalog changes (an addition, a metadata update, or a deletion). The Redeeming_Server records the highest Catalog_Version it has successfully applied as its Sync_Cursor for that Library_Connection and presents it to request only subsequent changes.
- **Changes_Since_API**: The Federation API endpoint on the Hosting_Server that, given a Sync_Cursor, returns the ordered set of Catalog changes (upserts and deletions, each identified by hosting-side id) that occurred after that cursor, together with the new Catalog_Version to adopt.
- **Catalog_Change**: A single entry returned by the Changes_Since_API describing either an **upsert** (a created or metadata-updated item, carrying its hosting-side id, type, metadata, and associations) or a **deletion** (a removed item, carrying its hosting-side id and type).
- **Full_Sync**: A synchronization that replaces the entire Catalog_Mirror for a Library_Connection with the Hosting_Server's current Catalog and adopts the current Catalog_Version as the Sync_Cursor.
- **Incremental_Sync**: A synchronization that requests only the Catalog_Changes after the recorded Sync_Cursor and applies them to the existing Catalog_Mirror, then advances the Sync_Cursor.
- **Catalog_Nudge**: A best-effort notification the Hosting_Server sends to Redeeming_Servers with active Access_Grants for a Library when that Library's Catalog changes, prompting an immediate Incremental_Sync. Delivery is not guaranteed and is never required for correctness.
- **Nudge_Endpoint**: The endpoint on the Redeeming_Server that receives a Catalog_Nudge for a Library_Connection and schedules an immediate Incremental_Sync.
- **Sync_Scheduler**: The Redeeming_Server component that periodically triggers an Incremental_Sync for each active Library_Connection at the configured Poll_Interval and on receipt of a Catalog_Nudge.
- **Poll_Interval**: The configurable duration between scheduled Incremental_Syncs for an active Library_Connection, with a defined default.
- **Sync_State**: A per-Library_Connection indicator of the Catalog_Mirror's synchronization condition, taking a value of `fresh` (the last sync succeeded), `stale` (the last sync attempt failed or the mirror has not synced within a staleness threshold and the last-known mirror is retained), or `unavailable` (the mirror has been torn down because the connection is revoked, unavailable, or deleted).
- **Last_Synced_At**: The timestamp of the most recent successful Full_Sync or Incremental_Sync for a Library_Connection.

## Requirements

### Requirement 1: Materialize a metadata-only catalog mirror on connection establishment

**User Story:** As a User who has redeemed a shared library, I want the remote library's catalog copied to my server as a browsable index, so that I can browse it quickly without a live round-trip for every request.

#### Acceptance Criteria

1. WHEN a Library_Connection to a Remote_Library is first established through a successful redemption, THE Redeeming_Server SHALL perform a Full_Sync that materializes the Remote_Library's Catalog as a Catalog_Mirror of Mirrored_Songs, Mirrored_Albums, and Mirrored_Artists associated with that Remote_Library.
2. WHEN the Redeeming_Server materializes a Mirrored_Song, THE Redeeming_Server SHALL store the Song's name, duration, track number, disc number, album association, artist association, and Remote_Song_Id.
3. WHEN the Redeeming_Server materializes a Mirrored_Album or a Mirrored_Artist, THE Redeeming_Server SHALL store the item's name, its metadata fields provided by the Hosting_Server, its artist association where applicable, and its hosting-side identifier.
4. THE Redeeming_Server SHALL store no audio byte content and no artwork byte content in the Catalog_Mirror.
5. THE Redeeming_Server SHALL associate every Mirrored_Song, Mirrored_Album, and Mirrored_Artist with exactly one Remote_Library.
6. WHEN a Full_Sync completes successfully, THE Redeeming_Server SHALL record the Hosting_Server's current Catalog_Version as the Sync_Cursor for the Library_Connection and SHALL set the Sync_State to `fresh`.
7. WHILE serving browsing, searching, and listing of a Remote_Library from its Catalog_Mirror, THE Redeeming_Server SHALL satisfy those browse, search, and list requests using local queries against the Catalog_Mirror and SHALL NOT make any live Federation API call to satisfy those browse, search, or list requests, while live Federation API calls remain permitted for synchronization and for live playback and artwork proxying.

### Requirement 2: Preserve associations and hosting identifiers in the mirror

**User Story:** As a User browsing a mirrored library, I want albums, artists, and tracks to relate to each other exactly as they do on the source, so that the shared library looks and behaves the same as it does on its owner's server.

#### Acceptance Criteria

1. WHEN the Redeeming_Server materializes a Mirrored_Song that references an album and an artist in the Hosting_Server's Catalog, THE Redeeming_Server SHALL associate that Mirrored_Song with the Mirrored_Album and Mirrored_Artist that carry the corresponding hosting-side identifiers.
2. THE Redeeming_Server SHALL identify each mirrored item by the pairing of its Library_Connection and its hosting-side identifier.
3. THE Redeeming_Server SHALL scope every mirrored item to its Remote_Library so that the Catalog_Mirror contains none of the current Server's Local_Library content and none of any other Library_Connection's mirrored content.
4. WHEN two distinct Library_Connections mirror content that shares the same hosting-side identifier value, THE Redeeming_Server SHALL keep the two Catalog_Mirrors separate so that neither connection's mirrored items are attributed to the other.
5. WHERE the Hosting_Server's Catalog associates a Mirrored_Song with an album or artist, THE Redeeming_Server SHALL preserve that association in the Catalog_Mirror after every Full_Sync and Incremental_Sync.

### Requirement 3: Provide a changes-since federation contract and catalog version cursor

**User Story:** As a Redeeming_Server, I want to ask the hosting server only for what changed since my last sync, so that ongoing synchronization is cheap and does not re-transfer the whole catalog.

#### Acceptance Criteria

1. THE Hosting_Server SHALL maintain a Catalog_Version for each Local_Library that increases monotonically whenever that Library's Catalog changes through an addition, a metadata update, or a deletion.
2. THE Hosting_Server SHALL expose a Changes_Since_API endpoint within the Federation API that accepts a Sync_Cursor and returns the ordered Catalog_Changes that occurred after that Sync_Cursor together with the Catalog_Version the Redeeming_Server is to adopt.
3. WHEN the Changes_Since_API receives a request, THE Hosting_Server SHALL authorize the presented grant token against a valid, non-revoked, non-expired Access_Grant that references the requested Library before returning any Catalog_Changes, and SHALL reject the request with an authorization error otherwise.
4. WHEN a content item is created or has its metadata updated on the Hosting_Server, THE Changes_Since_API SHALL represent that item as an upsert Catalog_Change carrying the item's hosting-side identifier, type, metadata, and associations.
5. WHEN a content item is removed on the Hosting_Server, THE Changes_Since_API SHALL represent that item as a deletion Catalog_Change carrying the item's hosting-side identifier and type.
6. WHEN a Redeeming_Server requests changes with a Sync_Cursor equal to or greater than the Hosting_Server's current Catalog_Version, THE Changes_Since_API SHALL return an empty set of Catalog_Changes and the current Catalog_Version.
7. WHEN a Redeeming_Server requests changes with a Sync_Cursor that the Hosting_Server can no longer serve incrementally, THE Changes_Since_API SHALL indicate that a Full_Sync is required rather than returning a partial change set.

### Requirement 4: Perform incremental synchronization on a configurable schedule

**User Story:** As a User, I want my mirror of a shared library to keep up with changes on the source automatically, so that what I browse stays current without manual refreshes.

#### Acceptance Criteria

1. WHILE a Library_Connection is active, THE Sync_Scheduler SHALL trigger an Incremental_Sync for that Library_Connection at intervals no longer apart than the configured Poll_Interval.
2. WHEN an Incremental_Sync runs, THE Redeeming_Server SHALL request Catalog_Changes from the Changes_Since_API using the Library_Connection's recorded Sync_Cursor.
3. WHEN an Incremental_Sync receives a set of Catalog_Changes, THE Redeeming_Server SHALL apply each upsert by creating or updating the corresponding mirrored item and each deletion by removing the corresponding mirrored item, then SHALL advance the Sync_Cursor to the Catalog_Version returned by the Changes_Since_API.
4. WHEN the Changes_Since_API indicates that a Full_Sync is required, THE Redeeming_Server SHALL perform a Full_Sync for the Library_Connection instead of applying an incremental change set.
5. THE Redeeming_Server SHALL provide a configurable Poll_Interval and SHALL apply a default Poll_Interval when no value is configured.
6. WHEN an Incremental_Sync completes successfully, THE Redeeming_Server SHALL set the Library_Connection's Sync_State to `fresh` and SHALL record the completion time as Last_Synced_At.

### Requirement 5: Propagate deletions from the host to the mirror

**User Story:** As a User, I want tracks removed from a shared library to disappear from my mirror, so that I never see or attempt to play content that no longer exists on the source.

#### Acceptance Criteria

1. WHEN an Incremental_Sync applies a deletion Catalog_Change for an item, THE Redeeming_Server SHALL remove the mirrored item identified by that Library_Connection and the item's hosting-side identifier from the Catalog_Mirror.
2. WHEN the Redeeming_Server removes a Mirrored_Song during synchronization, THE Redeeming_Server SHALL remove a Mirrored_Album or Mirrored_Artist if and only if no Mirrored_Song remains associated with that Mirrored_Album or Mirrored_Artist in the same Catalog_Mirror afterward.
3. WHEN a Full_Sync completes for a Library_Connection, THE Catalog_Mirror SHALL contain exactly the set of items present in the Hosting_Server's current Catalog, identified by hosting-side identifier, with no item that is absent from the current Catalog remaining in the mirror.
4. IF removing a mirrored item during synchronization fails due to a database error or concurrent access, THEN THE Redeeming_Server SHALL allow the synchronization to continue and SHALL leave that mirrored item in the Catalog_Mirror to be removed on a subsequent sync attempt.

### Requirement 6: Deliver a best-effort catalog-changed nudge that is never required for correctness

**User Story:** As a User, I want changes on a shared library to appear on my server promptly when possible, so that the mirror feels live, while still staying correct when my server cannot be reached directly.

#### Acceptance Criteria

1. WHEN a Local_Library's Catalog changes on the Hosting_Server, THE Hosting_Server SHALL send a best-effort Catalog_Nudge toward each Redeeming_Server that holds an active, non-revoked Access_Grant for that Library.
2. WHEN a Redeeming_Server receives a Catalog_Nudge for a Library_Connection at its Nudge_Endpoint, THE Redeeming_Server SHALL trigger an immediate Incremental_Sync for that Library_Connection.
3. IF the Hosting_Server cannot deliver a Catalog_Nudge to a Redeeming_Server because the Redeeming_Server is unreachable, THEN THE Hosting_Server SHALL treat the nudge as failed without retrying indefinitely and SHALL leave both the Catalog and the Access_Grant unchanged.
4. THE Redeeming_Server SHALL converge its Catalog_Mirror to the Hosting_Server's Catalog through the next scheduled Incremental_Sync whether or not any Catalog_Nudge was received.
5. WHEN a Redeeming_Server receives a Catalog_Nudge at its Nudge_Endpoint, THE Redeeming_Server SHALL accept the nudge only for a Library_Connection it holds and SHALL ignore a nudge that does not correspond to a known Library_Connection.

### Requirement 7: Retain the hosting song identifier for live playback and artwork

**User Story:** As a User, I want to play tracks and see artwork from a mirrored library, so that browsing an index that stores no media still lets me listen and view covers.

#### Acceptance Criteria

1. THE Redeeming_Server SHALL store the Remote_Song_Id on each Mirrored_Song so that audio can be fetched by the pairing of the Library_Connection and the Remote_Song_Id.
2. WHEN a User plays a Mirrored_Song, THE Redeeming_Server SHALL fetch the audio content live through the existing remote-stream proxy using the Library_Connection and the Mirrored_Song's Remote_Song_Id rather than from stored bytes.
3. IF the Hosting_Server is unavailable when a User plays a Mirrored_Song, THEN THE Redeeming_Server SHALL fail the playback request immediately and SHALL NOT fall back to any cached or stored audio.
4. WHEN a User views the artwork of a Mirrored_Album or Mirrored_Artist, THE Redeeming_Server SHALL fetch the artwork live through the Federation API asset endpoint using the Library_Connection and the item's hosting-side identifier rather than from stored bytes.
5. WHERE Path_Resolver resolves a Mirrored_Song, THE Redeeming_Server SHALL classify its Stream_Source as `remote` and produce a Resolved_Stream_Path through the same-origin remote-stream proxy.

### Requirement 8: Keep the mirror consistent, idempotent, and convergent

**User Story:** As a User, I want my mirror to end up matching the source no matter how syncs are ordered or repeated, so that I can trust that what I browse reflects the real shared library.

#### Acceptance Criteria

1. WHEN a synchronization for a Library_Connection completes successfully, THE Catalog_Mirror SHALL reflect exactly the Hosting_Server's Catalog as of the adopted Catalog_Version, with the same set of songs, albums, and artists by hosting-side identifier, no item absent from that Catalog remaining, and every association preserved.
2. WHEN the same set of Catalog_Changes is applied to a Catalog_Mirror more than once, THE resulting Catalog_Mirror SHALL be identical to the Catalog_Mirror produced by applying that set exactly once.
3. WHEN a Full_Sync and a series of Incremental_Syncs each advance a Library_Connection to the same Catalog_Version, THE resulting Catalog_Mirrors SHALL be identical.
4. THE Redeeming_Server SHALL leave no Mirrored_Song, Mirrored_Album, or Mirrored_Artist in the Catalog_Mirror whose hosting-side identifier is absent from the Hosting_Server's Catalog at the adopted Catalog_Version.

### Requirement 9: Tear down the mirror on revocation, unavailability, or deletion

**User Story:** As a Server_Owner sharing a library, I want a redeemer's mirror to stop being browsable once I revoke their access, so that revoking access actually removes reach to my catalog.

#### Acceptance Criteria

1. WHEN an Access_Grant is revoked or has expired and the Hosting_Server refuses a synchronization request with an authorization error, THE Redeeming_Server SHALL remove the Catalog_Mirror for that Library_Connection or SHALL mark the Catalog_Mirror unavailable so it is no longer browsable or served, and SHALL set the Sync_State to `unavailable`.
2. WHEN a Library_Connection's status becomes `revoked` or `unavailable`, THE Redeeming_Server SHALL stop serving the corresponding Catalog_Mirror for browsing, searching, and listing.
3. WHEN a Library_Connection is deleted, THE Redeeming_Server SHALL remove that Library_Connection's Catalog_Mirror in full, including every Mirrored_Song, Mirrored_Album, and Mirrored_Artist associated with the corresponding Remote_Library.
4. WHEN a Redeeming_Server requests synchronization for a Library_Connection, THE Redeeming_Server SHALL present the Library_Connection's grant token so the Hosting_Server authorizes the request against the Access_Grant, and SHALL treat an authorization rejection as a teardown or unavailability signal per Acceptance Criterion 1.
5. WHEN a Catalog_Mirror is removed or marked unavailable through teardown, THE Redeeming_Server SHALL leave the User's other Library_Connections and their Catalog_Mirrors unchanged.

### Requirement 10: Handle synchronization failures without corrupting or wiping the mirror

**User Story:** As a User, I want a temporary problem reaching the source to leave my existing mirror browsable, so that a network hiccup does not erase a library I was using.

#### Acceptance Criteria

1. IF the Hosting_Server is unreachable or does not respond within the Federation API content timeout budget during a synchronization, THEN THE Redeeming_Server SHALL retain the last-known Catalog_Mirror intact, SHALL leave the Sync_Cursor unchanged, and SHALL set the Sync_State to `stale`.
2. WHILE a Library_Connection's Sync_State is `stale`, THE Redeeming_Server SHALL continue to serve browsing from the last-known Catalog_Mirror and SHALL surface the staleness rather than presenting the mirror as fresh.
3. IF a synchronization fails partway through applying Catalog_Changes, THEN THE Redeeming_Server SHALL leave the Catalog_Mirror in the state it held before that synchronization began or in a state resumable from the recorded Sync_Cursor, and SHALL NOT leave the Catalog_Mirror partially updated with an advanced Sync_Cursor.
4. WHEN a synchronization that previously failed later succeeds, THE Redeeming_Server SHALL set the Sync_State to `fresh` and SHALL bring the Catalog_Mirror to the Hosting_Server's current Catalog.
5. THE Redeeming_Server SHALL apply synchronization timeout budgets consistent with the existing Federation API content timeout.

### Requirement 11: Exclude mirrored remote content from DAAP and RSP and treat it as a remote copy

**User Story:** As a Server_Owner, I want mirrored remote content kept out of my DAAP/RSP clients and treated as a remote copy in deduplication, so that mirroring for browsing speed does not change existing local-only serving and source-selection rules.

#### Acceptance Criteria

1. THE DAAP_Service and the RSP_Service SHALL serve only Authorized_Content drawn from Local_Libraries and SHALL exclude every Mirrored_Song, Mirrored_Album, and Mirrored_Artist of any Catalog_Mirror.
2. WHERE the Deduplicator or Source_Preference considers a Mirrored_Song, THE Redeeming_Server SHALL treat that Mirrored_Song as a remote copy that is available only while its Library_Connection is active.
3. WHILE a Library_Connection is not active, THE Redeeming_Server SHALL treat that connection's Mirrored_Songs as unavailable for both Source_Preference selection and Path_Resolver resolution together, so that those Mirrored_Songs are never available for one while unavailable for the other, consistent with existing remote-source behavior.
4. THE Redeeming_Server SHALL NOT expose any Mirrored_Song, Mirrored_Album, or Mirrored_Artist through the current Server's own Federation API endpoints.
