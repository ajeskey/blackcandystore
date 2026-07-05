# Requirements Document

## Introduction

Black Candy Store is a fork of the self-hosted Black Candy music streaming server (Ruby on Rails). This feature adds multi-library and cross-server library sharing, modeled after Plex.

Today a Black Candy server hosts a single implicit music collection derived from one media path. This feature introduces three capabilities:

1. **Multiple local libraries** — a server owner can define several named libraries on one server, each backed by its own media path, so music can be organized and shared selectively rather than as one monolithic collection.
2. **Invite-code-based sharing** — a server owner can generate an invite code scoped to a single library and give it to another person. Redeeming the code grants that person access to only that library.
3. **Cross-server access and access control** — a user on one server can redeem an invite code that points at a library on a different server, browse and stream that remote library, and the owning server can revoke access at any time.

The design keeps the existing single-media-path deployments working by treating the current collection as a default local library.

## Glossary

- **Server**: A running Black Candy Store instance identified by a stable public base URL.
- **Server_Owner**: An administrator user (existing `User` with `is_admin`) who manages libraries and sharing on a Server.
- **User**: An authenticated account on a Server (existing `User` model).
- **Library**: A named collection of music content (songs, albums, artists) scoped to a single media path on the Server that hosts it.
- **Local_Library**: A Library whose content and media files are hosted on the current Server.
- **Remote_Library**: A Library hosted on another Server that has been made accessible to the current Server through a redeemed Invite_Code.
- **Default_Library**: The Local_Library that represents the pre-existing single collection derived from the `MEDIA_PATH` configuration, created automatically on upgrade.
- **Invite_Code**: An opaque, single string token that encodes the issuing Server's base URL and a secret access token, and that grants access to exactly one Library when redeemed.
- **Access_Grant**: A record on the issuing Server that authorizes a specific redeemer to access a specific Local_Library, and that can be revoked.
- **Library_Connection**: A record on the redeeming Server that stores how to reach and authenticate against a Remote_Library.
- **Invite_Manager**: The Server component that generates, encodes, decodes, validates, and revokes Invite_Codes and Access_Grants.
- **Library_Scanner**: The Server component that scans a Library's media path and associates discovered content with that Library.
- **Library_Access_Controller**: The Server component that authorizes each request to read or stream content from a Library.
- **Active_Library**: The Library a User currently has selected for browsing.
- **Web_Player**: The browser-based audio player served by a Server that requests and plays a Song's audio content.
- **App_Player**: The mobile (native) application audio player that requests and plays a Song's audio content.
- **Stream_Source**: The classification of where a Song's audio content is served from, either `local` when the Song belongs to a Local_Library on the current Server or `remote` when the Song belongs to a Remote_Library.
- **Resolved_Stream_Path**: The absolute streaming URL that the Web_Player and App_Player use to request a Song's audio content, pointing to a path on the current Server for a `local` Stream_Source and to the hosting Server's streaming endpoint (reached through the Library_Connection) for a `remote` Stream_Source.
- **Displayable_Asset**: A cover art image (the existing `cover_image` attachment), an artist image, or another displayable metadata detail (such as album year, genre, or artist details) that a Web_Player, App_Player, or the API presents for a Song, Album, or Artist.
- **Asset_Source**: The classification of where a Displayable_Asset is served from, either `local` when the owning Album or Artist belongs to a Local_Library on the current Server or `remote` when it belongs to a Remote_Library.
- **Resolved_Asset_Path**: The absolute URL that the Web_Player, App_Player, and API use to fetch a Displayable_Asset, pointing to a path on the current Server for a `local` Asset_Source and to the hosting Server's asset endpoint (reached through the Library_Connection) for a `remote` Asset_Source.
- **Playlist**: The existing `Playlist` model, an ordered collection of Songs belonging to a User that MAY contain Songs whose Libraries are hosted on different Servers.
- **Source_Preference**: A per-User configurable setting that determines which source to resolve streaming from when the same content is available from more than one accessible source, taking the value `prefer_own_server` or `prefer_highest_quality`.
- **Deduplicator**: The Server component that identifies and groups Songs, Albums, and Artists across Libraries and Servers that represent the same underlying content.
- **Content_Fingerprint**: A content-derived identifier for a Song computed from the Song's `md5_hash` and audio fingerprint together with normalized core metadata (name, artist name, album name, and duration), used by the Deduplicator to match duplicate Songs.
- **Duplicate_Group**: A set of Songs across one or more Libraries or Servers that the Deduplicator has determined represent the same underlying content.
- **Logical_Track**: The single underlying track represented by a Duplicate_Group, for which the Source_Preference selects exactly one playable Song.
- **Output_Device**: A network-attached audio playback endpoint discovered by the Server on the local network to which the Server can send decoded audio for Server_Playback, being either an AirPlay_Device or a Chromecast_Device.
- **AirPlay_Device**: An Output_Device that receives audio using the AirPlay protocol, MAY be password-protected, and MAY be combined with other AirPlay_Devices into a synchronized multi-room group.
- **Chromecast_Device**: An Output_Device that receives audio using the Chromecast protocol.
- **Device_Discovery**: The Server component that discovers AirPlay_Devices and Chromecast_Devices advertised on the local network and maintains the current set of reachable Output_Devices.
- **Playback_Mode**: The classification of where a Song's audio originates during a playback activity, taking the value `client_cast` when the Web_Player or App_Player is the audio source and casts audio directly to an Output_Device, or `server_playback` when the Server is the audio source and decodes audio to Output_Devices for a Playback_Session.
- **Cast_Client**: The role played by the Web_Player or the App_Player when it acts as the audio source under the `client_cast` Playback_Mode by fetching a Song's audio content from the Song's Resolved_Stream_Path and streaming that audio content directly to a selected Output_Device.
- **Cast_Session**: A stateful client-side session on a Cast_Client that represents one `client_cast` activity, holding the target Output_Device, the current Song, and a cast state of `stopped`, `playing`, or `paused`.
- **Server_Playback**: The playback mode, corresponding to the `server_playback` Playback_Mode, in which the Server itself decodes a Song's audio and sends it to one or more selected Output_Devices, as distinct from the `client_cast` Playback_Mode in which the Web_Player or App_Player fetches a Resolved_Stream_Path and casts or plays audio itself.
- **Playback_Session**: A stateful Server-side session that represents one Server_Playback activity for a User, holding the set of active Output_Devices, the current Song, and a playback state of `stopped`, `playing`, or `paused`.
- **Playback_Controller**: The Server component that manages Playback_Sessions and applies play, resume, pause, stop, and volume control operations received through the API.
- **Remote_Control**: The role played by the Web_Player or App_Player when it issues Server_Playback control operations to a Playback_Session through the API rather than playing audio locally.
- **Media_Client**: An external application (such as an iTunes-style DAAP client or a Roku RSP client) that connects to the Server over DAAP or RSP to browse and download-and-play library content itself.
- **DAAP_Service**: The Server component that exposes authorized library content to DAAP Media_Clients and that can be enabled or disabled through a Server setting.
- **RSP_Service**: The Server component that exposes authorized library content to RSP Media_Clients and that can be enabled or disabled through a Server setting.
- **Authorized_Content**: For a given connecting Media_Client, the set of Songs, Albums, and Artists belonging to Libraries that the authenticated account behind that Media_Client is authorized to access under the same authorization model applied to browsing and streaming elsewhere in this specification.

## Requirements

### Requirement 1: Manage multiple local libraries

**User Story:** As a Server_Owner, I want to create and manage multiple named libraries on my server, so that I can organize my music and share subsets of it selectively.

#### Acceptance Criteria

1. WHEN a Server_Owner submits a new library with a name between 1 and 255 characters and a media path, THE Server SHALL create a Local_Library associated with that name and media path.
2. THE Server SHALL require every Local_Library to have a name that is unique within the Server.
3. IF a Server_Owner submits a library whose media path does not exist, THEN THE Server SHALL reject the submission and return a validation error stating that the media path does not exist.
4. IF a Server_Owner submits a library whose media path exists but is not readable, THEN THE Server SHALL reject the submission and return a validation error stating that the media path is not readable.
5. WHEN a Server_Owner renames a Local_Library to a name that is between 1 and 255 characters and unique within the Server, THE Server SHALL update the stored name while preserving the Library's existing content associations.
6. WHEN a Server_Owner deletes a Local_Library, THE Server SHALL remove the Library's content associations and all Access_Grants that reference that Library.
7. WHERE a Server has an existing single collection configured through `MEDIA_PATH` before this feature is installed, THE Server SHALL create a Default_Library referencing that media path and associate the pre-existing content with the Default_Library.
8. IF a request to create or modify a library is made by a User who is not a Server_Owner, THEN THE Server SHALL reject the request with an authorization error.
9. IF a Server_Owner submits a new library or renames an existing Library with a name that is empty, contains only whitespace, or exceeds 255 characters, THEN THE Server SHALL reject the request and return a validation error indicating the name length is invalid, and SHALL leave any existing Library unchanged.
10. IF a Server_Owner submits a new library or renames an existing Library with a name that duplicates an existing Local_Library name within the Server, THEN THE Server SHALL reject the request and return a validation error indicating the name is already in use, and SHALL leave any existing Library unchanged.
11. IF a Server_Owner submits a library and the existence of the media path cannot be confirmed because the media path existence check fails or times out, THEN THE Server SHALL reject the submission and return a validation error indicating that the media path could not be verified.

### Requirement 2: Scope music content to a library

**User Story:** As a Server_Owner, I want each library's music to be scanned and tracked separately, so that content stays associated with the correct library.

#### Acceptance Criteria

1. WHEN the Library_Scanner scans a Local_Library, THE Server SHALL associate each discovered song, album, and artist with that Local_Library.
2. THE Server SHALL associate every song with exactly one Library.
3. WHEN the same media file exists under the media paths of two different Local_Libraries, THE Server SHALL track each occurrence as a separate song associated with its respective Library.
4. WHEN a Local_Library is deleted, THE Server SHALL remove every song associated with that Library and SHALL remove an album or artist if and only if no song remains associated with that album or artist after those songs are removed.
5. WHEN a Local_Library is deleted, THE Server SHALL preserve every album and artist that has at least one remaining associated song after the deleted Library's songs are removed.
6. WHILE a Library_Scanner is scanning a Local_Library, THE Server SHALL report that Library's status as syncing.
7. WHEN a Library_Scanner completes scanning a Local_Library, THE Server SHALL report that Library's status as not syncing.
8. IF a Library_Scanner terminates before completing a scan of a Local_Library, THEN THE Server SHALL stop reporting that Library as syncing and record a scan-failure indication for that Library.

### Requirement 3: Browse content scoped to an accessible library

**User Story:** As a User, I want to browse only the library I have selected and am allowed to access, so that I see the correct music without seeing content I have no access to.

#### Acceptance Criteria

1. WHEN a User selects a Library the User is authorized to access as the Active_Library, THE Server SHALL record the selection for that User, replace any previously recorded Active_Library, and persist the selection across sessions.
2. WHILE a User has an Active_Library selected, THE Server SHALL restrict browsing, searching, and listing results to content of the Active_Library and SHALL exclude content of every other Library.
3. IF a User requests content of a Library the User is not authorized to access, THEN THE Library_Access_Controller SHALL reject the request with an authorization error and return none of that Library's content.
4. WHEN a User who has access to more than one Library requests the list of available libraries, THE Server SHALL return every Local_Library the User owns together with every Remote_Library the User has an active Library_Connection to.
5. WHERE a User has access to exactly one Library AND the User has no Active_Library recorded, THE Server SHALL set that Library as the Active_Library by default.
6. IF a User attempts to select a Library the User is not authorized to access as the Active_Library, THEN THE Server SHALL reject the request with an authorization error and leave the User's current Active_Library unchanged.
7. WHILE a User has access to zero Libraries, THE Server SHALL return empty browsing, searching, and listing results.
8. WHEN a User who has access to more than one Library requests the list of available libraries, THE Server SHALL include content of the User's current Active_Library in the response alongside the library list.
9. WHEN the Server rejects a User's attempt to select a Library the User is not authorized to access as the Active_Library, THE Server SHALL record the rejected selection attempt in the Server's logs or the User's history.

### Requirement 4: Generate an invite code for a library

**User Story:** As a Server_Owner, I want to generate an invite code scoped to a single library, so that I can share only that library with a specific person.

#### Acceptance Criteria

1. WHEN a Server_Owner requests an invite for a specific Local_Library, THE Invite_Manager SHALL create an Access_Grant for that Library and return one Invite_Code.
2. THE Invite_Manager SHALL generate each Invite_Code with at least 128 bits of cryptographic randomness in its secret token.
3. THE Invite_Manager SHALL encode the issuing Server's base URL and the secret token into the Invite_Code.
4. WHEN a Server_Owner requests an invite, THE Invite_Manager SHALL assign the Invite_Code an expiration timestamp defaulting to 7 days after creation.
5. WHERE a Server_Owner specifies an expiration duration between 1 minute and 365 days when requesting an invite, THE Invite_Manager SHALL assign an expiration timestamp equal to the creation time plus that duration instead of the 7-day default.
6. IF a User who is not the owner of the specified Local_Library requests an invite for that Library, THEN THE Invite_Manager SHALL reject the request with an authorization error and SHALL NOT create an Access_Grant.
7. FOR ALL generated Invite_Codes, decoding the Invite_Code SHALL yield the same issuing Server base URL and secret token that were encoded (round-trip property).
8. IF a Server_Owner specifies an expiration duration shorter than 1 minute or longer than 365 days when requesting an invite, THEN THE Invite_Manager SHALL reject the request with a validation error indicating the expiration duration is out of the allowed range and SHALL NOT create an Access_Grant.
9. IF a Server_Owner requests an invite for a Local_Library that does not exist on the current Server, THEN THE Invite_Manager SHALL reject the request with an error indicating the Library was not found and SHALL NOT create an Access_Grant.

### Requirement 5: Redeem an invite code

**User Story:** As a User, I want to redeem an invite code, so that I can gain access to the shared library it points to.

#### Acceptance Criteria

1. WHEN a User submits a well-formed Invite_Code that references a Local_Library on the current Server, THE Invite_Manager SHALL grant the User access to that Library and record the redemption against the Access_Grant.
2. WHEN a User submits a well-formed Invite_Code that references a Library on another Server AND the issuing Server confirms within 30 seconds that the Access_Grant is valid and not revoked, THE Server SHALL create a Library_Connection to that Remote_Library.
3. IF a User submits an Invite_Code that cannot be decoded into a Server base URL and a secret token, THEN THE Invite_Manager SHALL reject the redemption, leave any existing access unchanged, and return an error indicating that the Invite_Code is malformed.
4. IF a User submits an Invite_Code whose expiration timestamp is in the past AND the same User has not already redeemed that Invite_Code, THEN THE Invite_Manager SHALL reject the redemption with an expiration error.
5. IF a User submits an Invite_Code whose Access_Grant has been revoked, THEN THE Invite_Manager SHALL reject the redemption with an authorization error.
6. WHEN a User redeems an Invite_Code whose Access_Grant is not revoked and that the same User has already redeemed, THE Invite_Manager SHALL leave the existing access unchanged and report success even if the Invite_Code has expired.
7. IF a User submits a well-formed Invite_Code that references a Library on another Server AND the issuing Server is unreachable or does not respond within 30 seconds, THEN THE Server SHALL reject the redemption, not create a Library_Connection, and return an error indicating that the issuing Server is unavailable.
8. IF a User submits a well-formed Invite_Code that references a Library on another Server AND the issuing Server reports that the Access_Grant is invalid or revoked, THEN THE Server SHALL reject the redemption, not create a Library_Connection, and return an authorization error.
9. WHEN a User redeems an Invite_Code that references a Library on another Server that the same User has already redeemed, THE Server SHALL reuse the existing Library_Connection and SHALL NOT create a duplicate Library_Connection.

### Requirement 6: Access and stream a shared remote library

**User Story:** As a User, I want to browse and play music from a shared library on another server, so that I can enjoy content shared with me as if it were local.

#### Acceptance Criteria

1. WHILE a User has an active Library_Connection to a Remote_Library, THE Server SHALL list that Remote_Library's songs, albums, and artists to the User.
2. WHEN a User requests to stream a song from a Remote_Library, THE Server SHALL request the song's audio content from the hosting Server using the Library_Connection's stored credentials and stream the returned audio content to the User.
3. IF the hosting Server of a Remote_Library does not return a response within 10 seconds when a User requests its content, THEN THE Server SHALL return an error indicating the Remote_Library is unavailable and retain the Library_Connection unchanged.
4. WHEN a request for Remote_Library content is sent to the hosting Server, THE hosting Server's Library_Access_Controller SHALL verify the presented credentials against a valid, non-revoked Access_Grant before returning content.
5. IF the presented credentials for a Remote_Library request match an Access_Grant whose status is revoked or expired, THEN THE hosting Server SHALL reject the request and return an authorization error message to the requesting client rather than rejecting the request silently.
6. IF the presented credentials for a Remote_Library request do not match any stored Access_Grant, THEN THE hosting Server SHALL reject the request with an authorization error regardless of the outcome of any other validation or authorization mechanism.
7. IF the hosting Server rejects a Remote_Library content request with an authorization error, THEN THE requesting Server SHALL return an error to the User indicating access to the Remote_Library is no longer available and retain the User's other Library access unchanged.
8. WHEN the presented credentials for a Remote_Library request match a valid, non-revoked Access_Grant, THE hosting Server's Library_Access_Controller SHALL perform additional authorization checks before returning content and SHALL NOT authorize the request on the basis of the credential match alone.

### Requirement 7: Control and revoke shared access

**User Story:** As a Server_Owner, I want to see who has access to my libraries and revoke access, so that I remain in control of who can reach my music.

#### Acceptance Criteria

1. WHEN a Server_Owner requests the access list for a Local_Library, THE Server SHALL return every Access_Grant for that Library together with each grant's redemption status and expiration timestamp, returning an empty list when the Library has no Access_Grants.
2. WHEN a Server_Owner submits a request to revoke a specific Access_Grant identified in the request for a Local_Library the Server_Owner owns, THE Invite_Manager SHALL verify the Server_Owner's ownership of the Library and then mark the Access_Grant identified in the request as revoked and return confirmation that the Access_Grant is revoked.
3. WHEN a subsequent Remote_Library content request presents credentials tied to a revoked Access_Grant, THE Library_Access_Controller SHALL reject the request with an authorization error.
4. WHEN an Access_Grant is revoked, THE Invite_Manager SHALL reject future redemptions of the Invite_Code associated with that Access_Grant.
5. IF a User who is not the owner of a Local_Library attempts to view or revoke that Library's Access_Grants, THEN THE Server SHALL reject the request with an authorization error.
6. WHEN a Server_Owner revokes an Access_Grant, THE Server SHALL preserve the final state of every other Access_Grant for the same Local_Library unchanged.
7. IF a Server_Owner attempts to revoke an Access_Grant that already has revoked status, THEN THE Invite_Manager SHALL leave that Access_Grant revoked and report success without further change.
8. IF a Server_Owner attempts to revoke an Access_Grant that does not exist for a Local_Library the Server_Owner owns, THEN THE Server SHALL reject the request with a not-found error.
9. WHILE a revocation of an Access_Grant for a Local_Library is in progress, THE Server MAY temporarily lock other Access_Grants for that Local_Library, and THE Server SHALL restore each such temporarily locked Access_Grant to its prior value once the revocation completes.

### Requirement 8: Resolve streaming paths for local and remote songs

**User Story:** As a User, I want the Web_Player and App_Player to know where each song's audio is served from, so that I can play songs from both local and remote libraries without the player needing library-specific logic.

#### Acceptance Criteria

1. THE Server SHALL record for every Song the Library the Song belongs to and a Stream_Source of `local` when that Library is a Local_Library or `remote` when that Library is a Remote_Library.
2. WHERE a Song belongs to a Remote_Library, THE Server SHALL record with that Song the Library_Connection used to reach the hosting Server's streaming endpoint.
3. WHEN the Server returns a Song to the Web_Player or the App_Player, THE Server SHALL include the Song's Stream_Source and its Resolved_Stream_Path in the response.
4. WHERE a Song has a Stream_Source of `local`, THE Server SHALL set the Song's Resolved_Stream_Path to a streaming path on the current Server.
5. WHERE a Song has a Stream_Source of `remote`, THE Server SHALL set the Song's Resolved_Stream_Path to the hosting Server's streaming endpoint derived from the Song's Library_Connection.
6. WHEN the Web_Player requests audio for a Song, THE Web_Player SHALL request the audio content from that Song's Resolved_Stream_Path.
7. WHEN the App_Player requests audio for a Song, THE App_Player SHALL request the audio content from that Song's Resolved_Stream_Path.
8. WHERE a Song belongs to the Default_Library, THE Server SHALL set the Song's Stream_Source to `local` and its Resolved_Stream_Path to the same current-Server streaming path used before this feature was installed.
9. IF the Server returns a Song whose Library association cannot be determined, THEN THE Server SHALL set the Song's Stream_Source to `local` and its Resolved_Stream_Path to a streaming path on the current Server.
10. FOR ALL Songs returned to the Web_Player or the App_Player whose Stream_Source resolution succeeds, the response SHALL include a non-empty Resolved_Stream_Path.
11. IF a Song has a Stream_Source of `remote` AND its Library_Connection cannot be resolved to a streaming endpoint, THEN THE Server SHALL set that Song's Resolved_Stream_Path to empty, include an indication that the Song is currently unavailable, and preserve the Song's other attributes unchanged.
12. IF the Web_Player or the App_Player does not receive audio content from a Song's Resolved_Stream_Path within 30 seconds, THEN that player SHALL stop the request and indicate to the User that the Song is currently unavailable.
13. WHERE the same content is available to a User from more than one accessible source, THE Server SHALL determine the Resolved_Stream_Path from the source selected by the User's Source_Preference as specified in Requirement 11.

### Requirement 9: Resolve artwork and metadata paths for local and remote content

**User Story:** As a User, I want album cover art, artist images, and other displayable details to load correctly whether the content is local or remote, so that shared libraries look and behave the same as my own.

#### Acceptance Criteria

1. THE Server SHALL classify each Displayable_Asset of an Album or Artist with an Asset_Source of `local` when the owning Album or Artist belongs to a Local_Library or `remote` when the owning Album or Artist belongs to a Remote_Library.
2. WHEN the Server returns an Album or Artist to the Web_Player, the App_Player, or the API, THE Server SHALL include a Resolved_Asset_Path for each available Displayable_Asset of that Album or Artist.
3. WHERE a Displayable_Asset has an Asset_Source of `local`, THE Server SHALL set the Displayable_Asset's Resolved_Asset_Path to a path on the current Server.
4. WHERE a Displayable_Asset has an Asset_Source of `remote`, THE Server SHALL set the Displayable_Asset's Resolved_Asset_Path to the hosting Server's asset endpoint derived from the owning content's Library_Connection.
5. WHERE an Album or Artist has an existing `cover_image` attachment on the current Server created before this feature was installed, THE Server SHALL set that cover image's Asset_Source to `local` and its Resolved_Asset_Path to the same current-Server path used before this feature was installed.
6. WHEN the Server returns displayable metadata details for an Album or Artist that belongs to a Remote_Library, THE Server SHALL source those details from the hosting Server through the Library_Connection.
7. WHERE an Album or Artist has no cover image available from its source, THE Server SHALL set the Resolved_Asset_Path for that cover image to empty and indicate that the cover image is absent.
8. IF a Displayable_Asset has an Asset_Source of `remote` AND its owning content's Library_Connection cannot be resolved to an asset endpoint, THEN THE Server SHALL set that Displayable_Asset's Resolved_Asset_Path to empty, indicate that the asset is currently unavailable, and preserve the owning Album's or Artist's other attributes unchanged.
9. FOR ALL Albums and Artists returned to the Web_Player, the App_Player, or the API whose Asset_Source resolution succeeds and that have an available cover image, the response SHALL include a non-empty Resolved_Asset_Path for that cover image.

### Requirement 10: Route playlist songs across servers

**User Story:** As a User, I want a playlist to mix songs from my own library and shared remote libraries, so that each song plays from the correct location and one unavailable song does not break the whole playlist.

#### Acceptance Criteria

1. THE Server SHALL allow a Playlist to contain Songs whose Libraries are hosted on different Servers.
2. WHEN the Server returns a Playlist to the Web_Player, the App_Player, or the API, THE Server SHALL include for each Song in the Playlist that Song's Stream_Source and Resolved_Stream_Path.
3. WHEN a Playlist contains both `local` and `remote` Songs, THE Server SHALL resolve each Song's Resolved_Stream_Path independently according to that Song's Library.
4. IF a Song in a Playlist belongs to a Remote_Library whose Library_Connection access has been revoked, THEN THE Server SHALL mark that Song as unavailable, set that Song's Resolved_Stream_Path to empty, and return the remaining Songs of the Playlist with their Resolved_Stream_Paths unchanged.
5. IF a hosting Server is unavailable, THEN THE Server SHALL mark as unavailable and set to empty the Resolved_Stream_Path of only those Playlist Songs whose audio content is stored on that unavailable hosting Server, and SHALL return every other Song of the Playlist, including Songs hosted on other Servers and local Songs, with its Resolved_Stream_Path unchanged.
6. WHILE one or more Songs in a Playlist are unavailable, THE Server SHALL preserve the Playlist's order and membership so that each unavailable Song remains listed in its position.
7. FOR ALL Songs in a Playlist returned to the Web_Player, the App_Player, or the API, the response SHALL include a Stream_Source and, when that Song's Stream_Source resolution succeeds, a non-empty Resolved_Stream_Path.
8. IF a Song in a Playlist has a Stream_Source that cannot be resolved to a valid path, THEN THE Server SHALL include that Song in the Playlist response with an empty Resolved_Stream_Path and SHALL NOT reject the entire Playlist response.

### Requirement 11: Configure duplicate source preference

**User Story:** As a User, I want to choose which source a duplicated song streams from, so that I can favor my own copy or the highest-quality copy across the libraries I can access.

#### Acceptance Criteria

1. THE Server SHALL provide each User a Source_Preference setting whose value is either `prefer_own_server` or `prefer_highest_quality`.
2. WHERE a User has not configured a Source_Preference, THE Server SHALL treat that User's Source_Preference as `prefer_own_server`.
3. WHEN a User sets the Source_Preference to a supported value, THE Server SHALL persist the value and apply it to subsequent source resolution for that User.
4. WHERE a User's Source_Preference is `prefer_own_server` AND the same content is available from the User's own Local_Library and from one or more other accessible sources, THE Server SHALL resolve the Resolved_Stream_Path to the copy in the User's own Local_Library.
5. WHERE a User's Source_Preference is `prefer_highest_quality` AND the same content is available from more than one accessible source, THE Server SHALL resolve the Resolved_Stream_Path to the copy with the highest quality determined by lossless status first, then bit depth, then bitrate.
6. IF the source selected by a User's Source_Preference is unavailable, THEN THE Server SHALL resolve the Resolved_Stream_Path to the next source selected by the same Source_Preference among the remaining available sources.
7. IF a User's Source_Preference is `prefer_own_server` AND no copy of the content exists in the User's own Local_Library, THEN THE Server SHALL resolve the Resolved_Stream_Path to the highest-quality copy among the accessible sources.
8. IF two accessible copies are tied under the active Source_Preference, THEN THE Server SHALL select the copy in the User's own Local_Library first and otherwise SHALL select the copy by comparing the copies' actual Library identifiers and choosing the lowest actual Library identifier.
9. IF no accessible source remains for the content, THEN THE Server SHALL mark the content unavailable and set its Resolved_Stream_Path to empty.
10. IF a User submits a Source_Preference value that is not `prefer_own_server` or `prefer_highest_quality`, THEN THE Server SHALL reject the request with a validation error and leave the User's existing Source_Preference unchanged.

### Requirement 12: Deduplicate content across libraries

**User Story:** As a User, I want duplicate songs across my libraries recognized as the same track, so that they are grouped together and my source preference picks a single copy to play.

#### Acceptance Criteria

1. WHEN the Deduplicator evaluates two Songs, THE Deduplicator SHALL classify the two Songs as the same content when the two Songs' Content_Fingerprints match.
2. THE Deduplicator SHALL classify two Songs with identical `md5_hash` values as the same content.
3. WHEN the Deduplicator determines that a set of Songs across one or more Libraries or Servers represent the same content, THE Deduplicator SHALL group those Songs into a single Duplicate_Group representing one Logical_Track.
4. THE Deduplicator SHALL classify two Songs whose Content_Fingerprints do not match as distinct content and SHALL place the two Songs in different Duplicate_Groups.
5. WHERE Albums or Artists across Libraries have matching normalized identifying metadata, THE Deduplicator SHALL group those Albums or those Artists as the same Album or the same Artist respectively.
6. WHEN a Logical_Track is presented to a User, THE Server SHALL apply the User's Source_Preference to select exactly one Song from the Logical_Track's Duplicate_Group as the playable source and SHALL resolve that Song's Resolved_Stream_Path.
7. IF the Song selected as the playable source for a Logical_Track becomes unavailable, THEN THE Server SHALL select the next Song in the Duplicate_Group according to the User's Source_Preference.
8. FOR ALL Songs, the Deduplicator SHALL classify a Song as the same content as itself (reflexive property).
9. FOR ALL pairs of Songs A and B, IF the Deduplicator classifies A as the same content as B, THEN the Deduplicator SHALL classify B as the same content as A (symmetric property).
10. FOR ALL pairs of Songs A and B with identical Content_Fingerprints, THE Deduplicator SHALL place A and B in the same Duplicate_Group.
11. FOR ALL Duplicate_Groups under a given Source_Preference, THE Server SHALL select exactly one playable Song per Logical_Track.

### Requirement 13: Discover network output devices for server-driven playback

**User Story:** As a User, I want the Server to find AirPlay and Chromecast devices on my network, so that I can choose real speakers for the Server to play music on instead of only playing in my browser or app.

#### Acceptance Criteria

1. WHEN Device_Discovery runs, THE Server SHALL discover the AirPlay_Devices and Chromecast_Devices advertised on the local network and record each discovered device as an available Output_Device.
2. WHEN a User requests the list of available Output_Devices, THE Server SHALL return every currently reachable Output_Device together with each device's protocol classification of `airplay` or `chromecast` and an indication of whether the Output_Device requires a password.
3. WHEN an Output_Device that has been advertised stops being advertised on the local network, THE Server SHALL remove that Output_Device from the set of available Output_Devices regardless of the number of times that Output_Device was successfully discovered.
4. WHEN an AirPlay_Device advertises that it is password-protected, THE Server SHALL record that Output_Device as requiring a password.
5. IF Device_Discovery cannot enumerate Output_Devices on the local network, THEN THE Server SHALL return an empty set of available Output_Devices, and WHERE the Server can determine that device discovery is unavailable, THE Server SHALL also return an indication that device discovery is unavailable.
6. THE Server SHALL classify every discovered Output_Device as exactly one of `airplay` or `chromecast`.

### Requirement 14: Server-driven playback to selected output devices

**User Story:** As a User, I want to tell the Server to play a song on one or more chosen speakers and control it like a remote, so that I can enjoy multi-room audio driven by the Server rather than by my local device.

#### Acceptance Criteria

1. WHEN a User selects one or more available Output_Devices as active playback targets, THE Playback_Controller SHALL create or update a Playback_Session whose set of active Output_Devices equals the selected Output_Devices.
2. WHERE a User selects more than one AirPlay_Device as active playback targets, THE Playback_Controller SHALL send synchronized audio to every selected AirPlay_Device as a multi-room group.
3. WHEN a Remote_Control issues a play or resume operation for a Playback_Session that has at least one active Output_Device and a current Song, THE Playback_Controller SHALL decode the current Song's audio and send it to every active Output_Device and set the Playback_Session state to `playing`.
4. WHEN a Remote_Control issues a pause operation for a Playback_Session whose state is `playing`, THE Playback_Controller SHALL stop sending audio to the active Output_Devices, retain the current Song and playback position, and set the Playback_Session state to `paused`.
5. WHEN a Remote_Control issues a stop operation for a Playback_Session, THE Playback_Controller SHALL stop sending audio to the active Output_Devices, clear the current playback position, and set the Playback_Session state to `stopped`.
6. WHEN a Remote_Control issues a volume operation for a specific active Output_Device or for the active multi-room group of a Playback_Session, THE Playback_Controller SHALL set the volume of the targeted Output_Device or group to the requested level within the supported volume range.
7. WHERE a selected AirPlay_Device requires a password, THE Playback_Controller SHALL require a device password for that AirPlay_Device before sending audio to it.
8. IF the device password presented for a password-protected AirPlay_Device is missing or incorrect, THEN THE Playback_Controller SHALL reject the play operation for that AirPlay_Device with an authentication error and SHALL NOT send audio to that AirPlay_Device.
9. WHERE the current Song of a Playback_Session belongs to a Local_Library, THE Playback_Controller SHALL decode that Song's audio from the current Server for Server_Playback.
10. WHERE the current Song of a Playback_Session belongs to a Remote_Library, THE Playback_Controller SHALL retrieve that Song's audio content from the hosting Server through the Library_Connection as specified in Requirement 6 and then send the retrieved audio to the active Output_Devices.
11. IF an active Output_Device becomes unavailable or disconnects while a Playback_Session state is `playing`, THEN THE Playback_Controller SHALL remove that Output_Device from the Playback_Session's active Output_Devices and continue sending audio to any remaining active Output_Devices.
12. IF the last active Output_Device of a Playback_Session becomes unavailable while the Playback_Session state is `playing`, THEN THE Playback_Controller SHALL set the Playback_Session state to `stopped` and return an indication that playback stopped because no Output_Device remained available.
13. IF a User attempts to select an Output_Device that is not currently reachable as an active playback target, THEN THE Playback_Controller SHALL reject the selection with an error indicating the Output_Device is not reachable and leave the Playback_Session's active Output_Devices unchanged.
14. IF a Remote_Control issues a play or resume operation for a Playback_Session that has no active Output_Device, THEN THE Playback_Controller SHALL reject the operation with an error indicating that no Output_Device is selected and leave the Playback_Session state unchanged.
15. THE Playback_Controller SHALL keep every Playback_Session in exactly one of the states `stopped`, `playing`, or `paused` (state invariant).
16. FOR ALL Playback_Sessions, a resume operation applied after a pause operation with no intervening operation SHALL return the Playback_Session to the `playing` state with the same current Song and playback position that were retained at pause (state transition property).
17. WHEN a User under the `server_playback` Playback_Mode selects one or more available Output_Devices as active playback targets from the Web_Player, THE Playback_Controller SHALL create or update that User's Playback_Session with the selected Output_Devices so that the Server is the audio source.
18. WHEN a User under the `server_playback` Playback_Mode selects one or more available Output_Devices as active playback targets from the App_Player, THE Playback_Controller SHALL create or update that User's Playback_Session with the selected Output_Devices so that the Server is the audio source.
19. WHILE a Playback_Session state is `playing`, THE Server SHALL be the audio source for that Playback_Session and the Web_Player and the App_Player SHALL act only as a Remote_Control for that Playback_Session (audio-source invariant).

### Requirement 15: Serve the library to external media clients over DAAP and RSP

**User Story:** As a Server_Owner, I want my library served to iTunes-style DAAP clients and Roku RSP clients, so that people can browse and play my music from those clients while still only reaching content they are allowed to access.

#### Acceptance Criteria

1. WHERE the DAAP_Service is enabled, THE Server SHALL expose Authorized_Content to connecting DAAP Media_Clients so that those clients can browse and download-and-play that content.
2. WHERE the RSP_Service is enabled, THE Server SHALL expose Authorized_Content to connecting RSP Media_Clients so that those clients can browse and download-and-play that content.
3. THE Server SHALL provide a Server setting that independently enables or disables the DAAP_Service and a Server setting that independently enables or disables the RSP_Service.
4. WHERE the DAAP_Service is disabled, THE Server SHALL refuse DAAP connections and serve no library content over DAAP.
5. WHERE the RSP_Service is disabled, THE Server SHALL refuse RSP connections and serve no library content over RSP.
6. WHEN a Media_Client connects to the DAAP_Service or the RSP_Service, THE Server SHALL authenticate the Media_Client using the Server's existing authentication model before serving any library content.
7. IF a Media_Client fails authentication against the DAAP_Service or the RSP_Service, THEN THE Server SHALL reject the connection with an authentication error and serve no library content.
8. THE Server SHALL restrict the content the DAAP_Service and the RSP_Service serve to a Media_Client to the Local_Library content the authenticated account is authorized to access and SHALL NOT serve Remote_Library content over DAAP or RSP.
9. WHEN a Server_Owner revokes an authenticated account's authorization to a Local_Library, THE Server SHALL stop serving that Local_Library's content to that account's Media_Clients over the DAAP_Service and the RSP_Service.
10. FOR ALL content served by the DAAP_Service or the RSP_Service to a Media_Client, that content SHALL be a subset of the Authorized_Content for that Media_Client and SHALL contain no Remote_Library content (authorization containment property).

### Requirement 16: Choose a playback mode from either player

**User Story:** As a User, I want to choose whether my client casts audio directly to a speaker or the Server plays audio to the speaker, so that I can pick the routing that fits my situation from either the web or the app.

#### Acceptance Criteria

1. THE Server SHALL support exactly two Playback_Modes, `client_cast` and `server_playback`.
2. WHEN a User selects a Playback_Mode from the Web_Player, THE Server SHALL record that Playback_Mode as the User's selected Playback_Mode for subsequent playback activity.
3. WHEN a User selects a Playback_Mode from the App_Player, THE Server SHALL record that Playback_Mode as the User's selected Playback_Mode for subsequent playback activity.
4. IF a User submits a Playback_Mode value that is not `client_cast` or `server_playback`, THEN THE Server SHALL reject the request with a validation error and leave the User's selected Playback_Mode unchanged.
5. THE Server SHALL classify each active playback activity as exactly one Playback_Mode of `client_cast` or `server_playback` (mode invariant).
6. WHILE a playback activity's Playback_Mode is `client_cast` AND audio is being played for that playback activity, THE Cast_Client SHALL be the audio source and THE Server SHALL NOT be the audio source for that playback activity (audio-source invariant).
7. WHILE a playback activity's Playback_Mode is `server_playback`, THE Server SHALL be the audio source and neither THE Web_Player nor THE App_Player SHALL be the audio source for that playback activity (audio-source invariant).
8. WHERE a playback activity's Playback_Mode is `client_cast` AND no audio source is currently active for that playback activity, THE Server SHALL permit the `client_cast` Playback_Mode and SHALL NOT require an active audio source for that playback activity.

### Requirement 17: Cast audio directly from a client to an output device

**User Story:** As a User, I want to cast audio directly from my browser or app to an AirPlay or Chromecast device, so that my client acts as the audio source and plays music on a real speaker without routing the audio through the Server.

#### Acceptance Criteria

1. WHEN a User selects a reachable Output_Device as the cast target from the Web_Player under the `client_cast` Playback_Mode, THE Web_Player SHALL act as the Cast_Client and create a Cast_Session whose target Output_Device is the selected Output_Device.
2. WHEN a User selects a reachable Output_Device as the cast target from the App_Player under the `client_cast` Playback_Mode, THE App_Player SHALL act as the Cast_Client and create a Cast_Session whose target Output_Device is the selected Output_Device.
3. WHEN a Cast_Client begins casting a Song, THE Cast_Client SHALL obtain the Song's audio content from the Song's Resolved_Stream_Path and stream that audio content directly to the target Output_Device.
4. WHERE the Song being cast has a Stream_Source of `remote`, THE Cast_Client SHALL obtain the Song's audio content from the Song's Resolved_Stream_Path in the same manner as a Song with a Stream_Source of `local`, as resolved in Requirement 8.
5. WHEN a User issues a play or resume operation for a Cast_Session from the Cast_Client, THE Cast_Client SHALL stream the current Song's audio content to the target Output_Device and set the Cast_Session state to `playing`.
6. WHEN a User issues a pause operation for a Cast_Session whose state is `playing` from the Cast_Client, THE Cast_Client SHALL stop streaming audio to the target Output_Device, retain the current Song and playback position, and set the Cast_Session state to `paused`.
7. WHEN a User issues a stop operation for a Cast_Session from the Cast_Client, THE Cast_Client SHALL stop streaming audio to the target Output_Device, clear the current playback position, and set the Cast_Session state to `stopped`.
8. WHEN a User issues a volume operation for a Cast_Session from the Cast_Client, THE Cast_Client SHALL set the volume of the target Output_Device to the requested level within the supported volume range.
9. WHERE the target Output_Device of a Cast_Session is a password-protected AirPlay_Device, THE Cast_Client SHALL require a device password for that AirPlay_Device before streaming audio to it.
10. IF the device password presented for a password-protected AirPlay_Device is missing or incorrect, THEN THE Cast_Client SHALL reject the cast operation with an authentication error and SHALL NOT stream audio to that AirPlay_Device.
11. IF the target Output_Device of a Cast_Session is not reachable when the Cast_Client attempts to begin casting, THEN THE Cast_Client SHALL reject the cast operation with an error indicating the Output_Device is not reachable and set the Cast_Session state to `stopped`.
12. IF the target Output_Device of a Cast_Session disconnects while the Cast_Session state is `playing`, THEN THE Cast_Client SHALL set the Cast_Session state to `stopped` and indicate to the User that casting stopped because the Output_Device disconnected.
13. IF the Cast_Client does not obtain audio content from the Song's Resolved_Stream_Path within 30 seconds, THEN THE Cast_Client SHALL stop the cast operation and indicate to the User that the Song is currently unavailable.
14. THE Cast_Client SHALL keep every Cast_Session in exactly one of the states `stopped`, `playing`, or `paused` (state invariant).
15. WHILE a Cast_Session state is `playing`, THE Cast_Client SHALL be the audio source for that Cast_Session and THE Server SHALL NOT decode or send the cast Song's audio to the target Output_Device (audio-source invariant).
16. FOR ALL Cast_Sessions, a resume operation applied after a pause operation with no intervening operation SHALL return the Cast_Session to the `playing` state with the same current Song and playback position that were retained at pause (state transition property).

### Requirement 18: Keep client-cast and server-playback modes mutually distinct

**User Story:** As a User, I want the two playback routing models to stay clearly separated, so that I always know whether my client or the Server is the audio source and controls behave predictably.

#### Acceptance Criteria

1. THE Server SHALL treat the `client_cast` Playback_Mode and the `server_playback` Playback_Mode as mutually exclusive for a single playback activity.
2. WHILE a User's playback activity uses the `client_cast` Playback_Mode, THE Server SHALL manage that activity through a Cast_Session on the Cast_Client and SHALL NOT manage that activity through a Playback_Session.
3. WHILE a User's playback activity uses the `server_playback` Playback_Mode, THE Server SHALL manage that activity through a Playback_Session and SHALL NOT manage that activity through a Cast_Session.
4. FOR ALL playback activities, IF the Playback_Mode is `client_cast`, THEN the audio source SHALL be the Cast_Client and SHALL NOT be the Server (audio-source containment property).
5. FOR ALL playback activities, IF the Playback_Mode is `server_playback`, THEN the audio source SHALL be the Server and SHALL NOT be the Web_Player or the App_Player (audio-source containment property).
6. WHILE more than one `client_cast` playback activity exists at the same time, THE Server SHALL manage every such `client_cast` playback activity through a Cast_Session and SHALL NOT leave any concurrent `client_cast` playback activity unmanaged.
