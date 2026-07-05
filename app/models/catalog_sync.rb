# frozen_string_literal: true

# CatalogSync is the redeeming-side engine that materializes and reconciles a
# Remote_Library's Catalog_Mirror. This file implements only the pure **apply**
# step (`CatalogSync.apply`); the Full_Sync / Incremental_Sync drivers that
# fetch changes over the Federation API and manage the transaction, cursor, and
# Sync_State live alongside it in a later task.
#
# `apply(connection, changes)` takes the connection whose remote Library is
# `connection.library` and an ordered list of Catalog_Changes and mutates the
# mirror in place to reflect them, returning the mirror Library.
#
# Input shape (`changes`)
# ------------------------
# `changes` is the ordered `changes` array produced by the Changes_Since_API and
# parsed by `Federation::Client#changes_since` (so keys arrive as strings; both
# string and symbol keys are accepted here via indifferent access). Each entry
# mirrors `app/views/federation/changes/index.json.jbuilder`:
#
#   upsert song    { "change_type" => "upsert", "item_type" => "song", "id" => <remote_song_id>,
#                    "name", "duration", "tracknum", "discnum",
#                    "album_id" => <remote_album_id>, "album_name",
#                    "artist_id" => <remote_artist_id>, "artist_name", ... }
#   upsert album   { "change_type" => "upsert", "item_type" => "album", "id" => <remote_album_id>,
#                    "name", "year", "genre", "artist_id" => <remote_artist_id>, "artist_name", ... }
#   upsert artist  { "change_type" => "upsert", "item_type" => "artist", "id" => <remote_artist_id>,
#                    "name", "is_various", ... }
#   deletion       { "change_type" => "deletion", "item_type" => "song|album|artist", "id" => <remote_id> }
#
# `id` is always the item's hosting-side identifier (its remote_*_id); the
# `album_id`/`artist_id` an upsert carries are likewise hosting-side ids, which
# this engine resolves to the mirrored rows carrying the matching remote ids
# (Req 2.1, 2.5).
#
# Idempotence (Req 8.2)
# ---------------------
# Every upsert is keyed on the row's `(library_id, remote_*_id)` unique index
# via `create_or_find_by!` and then updated to the change's values, so applying
# the same change set once or many times yields identical rows.
module CatalogSync
  module_function

  # Apply an ordered list of Catalog_Changes to `connection`'s Catalog_Mirror.
  #
  # Upserts propagate their error so the caller's surrounding transaction can
  # roll the whole sync back on failure (Req 10.3). Each deletion is isolated in
  # its own savepoint so a single failing deletion is tolerated and the item is
  # left in the mirror for a later sync without aborting the rest of the apply
  # (Req 5.4).
  #
  # @param connection [LibraryConnection] the connection whose remote Library is
  #   the Catalog_Mirror being reconciled.
  # @param changes [Array<Hash>] the ordered `changes` array from a
  #   changes-since response (string- or symbol-keyed hashes).
  # @return [Library] the mirror Library.
  def apply(connection, changes)
    library = connection.library
    needs_orphan_cleanup = false

    Array(changes).each do |raw_change|
      change = raw_change.to_h.with_indifferent_access

      case change[:change_type].to_s
      when "upsert"
        apply_upsert(library, change)
      when "deletion"
        apply_deletion(library, change)
        needs_orphan_cleanup = true
      end
    end

    # Orphan cleanup is deferred to a single pass over the whole change set
    # rather than run per-deletion. Running it mid-set would remove an
    # album/artist left *transiently* songless by an earlier deletion even when
    # a later upsert in the same set re-references it — and that later upsert
    # would then resurrect the row through the create-only association path in
    # `ensure_album`/`ensure_artist`, which seeds only the association and
    # leaves owned metadata (album year/genre, ...) blank. On a second
    # application the row already has a song, survives, and keeps the full
    # metadata from its explicit upsert, so `apply(apply(M,C),C) != apply(M,C)`.
    # Deferring to one final pass makes an album/artist removed iff *no*
    # mirrored song remains for it after the entire set is applied (Req 5.2),
    # so transient mid-set orphans that get re-referenced survive — giving
    # idempotent and convergent results (Req 8.2, 8.3). Cleanup is triggered
    # only when the set carried a deletion; an upsert-only set can create no
    # orphans it should remove.
    clean_up_orphans(library) if needs_orphan_cleanup

    library
  end

  # --- Sync drivers ---------------------------------------------------------

  # Replace the entire Catalog_Mirror for `connection` with the Hosting_Server's
  # current Catalog and adopt its Catalog_Version as the Sync_Cursor
  # (Req 1.1, 1.5, 1.6, 5.3, 8.1, 8.4).
  #
  # The host Catalog is fetched with the existing `Federation::Client` browse
  # calls (songs/albums/artists, paged) and transformed into the same upsert
  # `changes` shape `apply` consumes, so the mirror ends up carrying the
  # identical field set local browsing produces. After applying every upsert,
  # any mirrored row whose hosting-side id is absent from the fetched Catalog is
  # removed so the mirror contains exactly the host's current set (Req 8.4).
  #
  # The adopted `catalog_version` is read from the host **before** browsing so a
  # concurrent host change during the browse is caught by the next incremental
  # sync rather than silently skipped (a conservative cursor). When `full_sync`
  # is reached from `incremental_sync`'s `full_sync_required` branch the version
  # is already known and is passed in to avoid a redundant round trip.
  #
  # Atomicity (Req 10.3): the apply, the absent-row removal, and the cursor
  # advance run in a single `ActiveRecord::Base.transaction`, so a failure
  # partway rolls the whole rebuild back and never leaves a partial mirror with
  # an advanced cursor.
  #
  # On a transport failure (Req 10.1): every browse call happens before the
  # transaction opens, so an `Unreachable`/`Timeout` leaves the last-known
  # mirror and the Sync_Cursor untouched; the connection is marked `stale` and
  # keeps serving, surfacing staleness rather than wiping the mirror (Req 10.2).
  #
  # @param connection [LibraryConnection] the connection whose remote Library is
  #   the Catalog_Mirror to rebuild.
  # @param catalog_version [Integer, nil] the version to adopt when already
  #   known (from the `full_sync_required` branch); read from the host otherwise.
  # @return [LibraryConnection] the connection, with its Sync_State updated.
  def full_sync(connection, catalog_version: nil)
    client = build_client(connection)
    library_id = connection.remote_library_id

    catalog_version ||= fetch_catalog_version(client, library_id, connection.sync_cursor)
    changes = fetch_full_catalog(client, library_id)

    ActiveRecord::Base.transaction do
      apply(connection, changes)
      remove_absent(connection.library, changes)
      mark_fresh(connection, catalog_version)
    end

    connection
  rescue Federation::Client::Unauthorized
    tear_down(connection)
    connection
  rescue Federation::Client::Unreachable, Federation::Client::Timeout
    mark_stale(connection)
    connection
  end

  # Request only the Catalog_Changes after the recorded Sync_Cursor and apply
  # them, then advance the Sync_Cursor to the returned Catalog_Version
  # (Req 4.2, 4.3, 4.6). Falls back to a Full_Sync when the host can no longer
  # serve the cursor incrementally (Req 4.4).
  #
  # The delta is paginated; every page after the recorded cursor is collected
  # before the cursor advances, so a multi-page change set is applied in full
  # and the mirror converges to the adopted version rather than skipping the
  # pages beyond the first (Req 8.1). All pages describe the same
  # `catalog_version`, so the cursor is advanced to it once, after the whole
  # delta is applied.
  #
  # Atomicity (Req 10.3): the apply and the cursor advance run in a single
  # transaction. On a transport failure (Req 10.1) the fetch happens before the
  # transaction opens, so the mirror and cursor are left unchanged and the
  # connection is marked `stale`, continuing to serve (Req 10.2).
  #
  # @param connection [LibraryConnection] the connection to synchronize.
  # @return [LibraryConnection] the connection, with its Sync_State updated.
  def incremental_sync(connection)
    client = build_client(connection)
    library_id = connection.remote_library_id
    cursor = connection.sync_cursor

    first = client.changes_since(library_id, cursor, 1)

    # Req 4.4: the host cannot serve this cursor incrementally — rebuild the
    # whole mirror instead, reusing the version the host already told us.
    return full_sync(connection, catalog_version: first["catalog_version"]) if truthy(first["full_sync_required"])

    catalog_version = first["catalog_version"]
    changes = collect_change_pages(client, library_id, cursor, first)

    ActiveRecord::Base.transaction do
      apply(connection, changes)
      mark_fresh(connection, catalog_version)
    end

    connection
  rescue Federation::Client::Unauthorized
    tear_down(connection)
    connection
  rescue Federation::Client::Unreachable, Federation::Client::Timeout
    mark_stale(connection)
    connection
  end

  # Tear down a Catalog_Mirror when the host refuses synchronization with an
  # authorization error — a `Federation::Client::Unauthorized` (HTTP 401/403)
  # raised by `changes_since`/`browse` because the Access_Grant was revoked or
  # has expired (Req 9.1, 9.4).
  #
  # Rather than deleting the mirror's rows, the mirror is marked **unavailable**
  # so it is no longer browsable or served — the connection's lifecycle `status`
  # transitions to `revoked` (an authorization rejection means the host reports
  # the grant is no longer valid) and its `sync_state` becomes `unavailable`.
  # A non-active status is exactly what `browsable_active_library` and the
  # `RemoteAvailability` predicate already key on, so browse/search/list stop
  # serving this mirror without any content deletion (Req 9.1, 9.2).
  #
  # The update touches only this connection's own row, and every mirrored item
  # is `library_id`-scoped to this connection's Remote_Library, so every other
  # connection's mirror is left entirely unchanged (Req 9.5).
  def tear_down(connection)
    connection.update!(status: "revoked", sync_state: "unavailable")
  end
  private_class_method :tear_down

  # --- Sync driver helpers --------------------------------------------------

  # Build a Federation::Client for a connection from its stored hosting base URL
  # and grant token, exactly as the redemption and stream-proxy paths do.
  def build_client(connection)
    Federation::Client.new(
      base_url: connection.server_base_url,
      grant_token: connection.grant_token
    )
  end
  private_class_method :build_client

  # Read the host's current Catalog_Version without applying any change, by
  # asking the Changes_Since_API from the recorded cursor and taking only the
  # version it reports. Used by a standalone Full_Sync (first connection) that
  # has no prior changes response to source the version from.
  def fetch_catalog_version(client, library_id, cursor)
    response = client.changes_since(library_id, cursor)
    response["catalog_version"].to_i
  end
  private_class_method :fetch_catalog_version

  # Fetch the host's entire Catalog and transform it into an ordered upsert
  # `changes` set `apply` consumes. Artists precede albums precede songs so the
  # association targets exist as each level is applied.
  def fetch_full_catalog(client, library_id)
    artists = browse_all(client, library_id, "artists").map { |artist| artist_upsert(artist) }
    albums = browse_all(client, library_id, "albums").map { |album| album_upsert(album) }
    songs = browse_all(client, library_id, "songs").map { |song| song_upsert(song) }

    artists + albums + songs
  end
  private_class_method :fetch_full_catalog

  # Page through a browse endpoint until it stops returning rows, accumulating
  # the full list. A page past the last one comes back empty and ends the loop.
  def browse_all(client, library_id, type)
    results = []
    page = 1

    loop do
      batch = Array(client.browse(library_id, type, page: page))
      break if batch.empty?

      results.concat(batch)
      page += 1
    end

    results
  end
  private_class_method :browse_all

  # Collect every page of an incremental delta after `cursor`, seeding with the
  # already-fetched first page. Stops when a page carries no further changes.
  def collect_change_pages(client, library_id, cursor, first_response)
    changes = Array(first_response["changes"])
    page = 2

    loop do
      body = client.changes_since(library_id, cursor, page)
      page_changes = Array(body["changes"])
      break if page_changes.empty?

      changes.concat(page_changes)
      page += 1
    end

    changes
  end
  private_class_method :collect_change_pages

  # Map a browsed artist row to the upsert change shape (Req 1.3).
  def artist_upsert(artist)
    artist = artist.to_h.with_indifferent_access
    {
      "change_type" => "upsert", "item_type" => "artist",
      "id" => artist[:id],
      "name" => artist[:name],
      "is_various" => artist[:is_various]
    }
  end
  private_class_method :artist_upsert

  # Map a browsed album row to the upsert change shape, carrying its hosting-side
  # artist association (Req 1.3, 2.1).
  def album_upsert(album)
    album = album.to_h.with_indifferent_access
    {
      "change_type" => "upsert", "item_type" => "album",
      "id" => album[:id],
      "name" => album[:name],
      "year" => album[:year],
      "genre" => album[:genre],
      "artist_id" => album[:artist_id],
      "artist_name" => album[:artist_name]
    }
  end
  private_class_method :album_upsert

  # Map a browsed song row to the upsert change shape, carrying its hosting-side
  # album/artist associations (Req 1.2, 2.1). This is the identical field set
  # the Changes_Since feed produces for a song upsert, so a Full_Sync and an
  # Incremental_Sync to the same version converge to identical mirrors (Req 8.3).
  def song_upsert(song)
    song = song.to_h.with_indifferent_access
    {
      "change_type" => "upsert", "item_type" => "song",
      "id" => song[:id],
      "name" => song[:name],
      "duration" => song[:duration],
      "tracknum" => song[:tracknum],
      "discnum" => song[:discnum],
      "album_id" => song[:album_id],
      "album_name" => song[:album_name],
      "artist_id" => song[:artist_id],
      "artist_name" => song[:artist_name]
    }
  end
  private_class_method :song_upsert

  # Remove every mirrored row whose hosting-side id is absent from the freshly
  # fetched Catalog, so a Full_Sync leaves the mirror equal to exactly the
  # host's current set (Req 5.3, 8.4). Songs are destroyed (running their own
  # dependent cleanup); albums/artists are deleted directly to avoid the
  # `dependent: :destroy` cascade removing rows that are still present, matching
  # the deletion strategy in the pure apply step. Order (songs, albums, artists)
  # respects the association graph.
  def remove_absent(library, changes)
    song_ids = upsert_ids(changes, "song")
    album_ids = upsert_ids(changes, "album")
    artist_ids = upsert_ids(changes, "artist")

    library.songs.where.not(remote_song_id: song_ids).find_each(&:destroy!)
    library.albums.where.not(remote_album_id: album_ids).delete_all
    library.artists.where.not(remote_artist_id: artist_ids).delete_all
  end
  private_class_method :remove_absent

  # The hosting-side ids of every upsert of a given item type in a change set.
  def upsert_ids(changes, item_type)
    Array(changes).filter_map do |raw_change|
      change = raw_change.to_h.with_indifferent_access
      next unless change[:change_type].to_s == "upsert" && change[:item_type].to_s == item_type

      change[:id]
    end
  end
  private_class_method :upsert_ids

  # Record a successful sync: adopt the host's Catalog_Version as the
  # Sync_Cursor, mark the mirror `fresh`, and stamp Last_Synced_At (Req 1.6,
  # 4.3, 4.6, 10.4). Called inside the sync transaction so the cursor advance
  # commits atomically with the applied changes (Req 10.3).
  def mark_fresh(connection, catalog_version)
    connection.update!(
      sync_cursor: catalog_version,
      sync_state: "fresh",
      last_synced_at: Time.current
    )
  end
  private_class_method :mark_fresh

  # Record a transient sync failure: retain the last-known mirror and the
  # Sync_Cursor unchanged and only mark the mirror `stale` so it keeps serving
  # and surfaces its staleness (Req 10.1, 10.2).
  def mark_stale(connection)
    connection.update!(sync_state: "stale")
  end
  private_class_method :mark_stale

  # --- Upserts --------------------------------------------------------------

  def apply_upsert(library, change)
    case change[:item_type].to_s
    when "artist" then upsert_artist(library, change)
    when "album" then upsert_album(library, change)
    when "song" then upsert_song(library, change)
    end
  end
  private_class_method :apply_upsert

  # Create-or-find the Mirrored_Artist by (library_id, remote_artist_id) and set
  # its metadata to the change's values (Req 1.3, 2.3).
  def upsert_artist(library, change)
    artist = ensure_artist(library, remote_artist_id: change[:id], name: change[:name])
    artist.update!(name: artist_name(change[:name]), various: truthy(change[:is_various]))
    artist
  end
  private_class_method :upsert_artist

  # Create-or-find the Mirrored_Album by (library_id, remote_album_id), wiring
  # its artist association to the Mirrored_Artist carrying the matching
  # hosting-side id, and set its metadata (Req 1.3, 2.1, 2.5).
  def upsert_album(library, change)
    artist = ensure_artist(library, remote_artist_id: change[:artist_id], name: change[:artist_name])
    album = ensure_album(library, remote_album_id: change[:id], name: change[:name], artist: artist)
    album.update!(
      name: album_name(change[:name]),
      year: change[:year],
      genre: change[:genre],
      artist_id: artist.id
    )
    album
  end
  private_class_method :upsert_album

  # Create-or-find the Mirrored_Song by (library_id, remote_song_id), wiring its
  # album/artist associations to the mirrored rows carrying the matching
  # hosting-side ids, and set its metadata (Req 1.2, 2.1, 2.5). The mirror
  # stores no file: file_path/md5_hash stay null on remote songs (Req 1.4).
  def upsert_song(library, change)
    artist = ensure_artist(library, remote_artist_id: change[:artist_id], name: change[:artist_name])
    album = ensure_album(library, remote_album_id: change[:album_id], name: change[:album_name], artist: artist)

    song = library.songs.create_or_find_by!(remote_song_id: change[:id]) do |new_song|
      new_song.name = song_name(change[:name])
      new_song.album_id = album.id
      new_song.artist_id = artist.id
    end

    song.update!(
      name: song_name(change[:name]),
      duration: change[:duration] || 0.0,
      tracknum: change[:tracknum],
      discnum: change[:discnum],
      album_id: album.id,
      artist_id: artist.id
    )
    song
  end
  private_class_method :upsert_song

  # Resolve (creating if necessary) the Mirrored_Artist for a hosting-side
  # artist id within this mirror. Only the create path sets the name — an
  # existing row's metadata is owned by its own artist upsert and is not
  # clobbered by an association lookup coming from an album/song upsert.
  def ensure_artist(library, remote_artist_id:, name:)
    library.artists.create_or_find_by!(remote_artist_id: remote_artist_id) do |artist|
      artist.name = artist_name(name)
    end
  end
  private_class_method :ensure_artist

  # Resolve (creating if necessary) the Mirrored_Album for a hosting-side album
  # id within this mirror, wiring the artist association. The create path seeds
  # the descriptive name, which stays owned by the album's own upsert. The
  # artist *association*, however, is re-resolved by hosting-side id on every
  # pass — never left create-only.
  #
  # Associations are stored by local autoincrement id, but a Mirrored_Artist's
  # identity is its `(library, remote_artist_id)` pairing. When an artist is
  # deleted and re-created within a change set or across applications (via
  # `create_or_find_by!`) it takes a *new* local id. A create-only link would
  # then leave an existing album pointing at the artist's stale/removed local id
  # — a dangling reference whose resolution differs between the first and second
  # application, breaking idempotence (Req 8.2) and convergence (Req 8.3).
  # Re-pointing to the current artist row for the hosting-side id keeps the
  # album linked to the Mirrored_Artist carrying the matching id (Req 2.1, 2.5)
  # and makes the pass a fixed point, exactly as `upsert_song` already
  # re-resolves a song's album/artist ids on every apply.
  def ensure_album(library, remote_album_id:, name:, artist:)
    album = library.albums.create_or_find_by!(remote_album_id: remote_album_id) do |new_album|
      new_album.name = album_name(name)
      new_album.artist_id = artist.id
    end

    album.update!(artist_id: artist.id) unless album.artist_id == artist.id
    album
  end
  private_class_method :ensure_album

  # --- Deletions ------------------------------------------------------------

  # Remove the mirrored item identified by (library, hosting-side id). Orphaned
  # albums/artists are NOT dropped here — that is deferred to a single
  # `clean_up_orphans` pass after the whole change set is applied (see `apply`)
  # so a transiently-orphaned row re-referenced by a later upsert survives
  # (Req 5.1, 5.2, 8.2).
  #
  # The deletion runs in a nested transaction (savepoint) so that a failure — a
  # database error or a concurrent change — rolls back only this item and is
  # tolerated, leaving the item in the mirror to be removed on a later sync
  # without aborting the surrounding apply (Req 5.4).
  def apply_deletion(library, change)
    ActiveRecord::Base.transaction(requires_new: true) do
      record = deletion_target(library, change)
      next if record.nil?

      remove_identified(record)
    end
  rescue ActiveRecord::ActiveRecordError
    # Req 5.4: tolerate a per-item deletion failure and leave the item in place
    # for a subsequent sync to remove.
    nil
  end
  private_class_method :apply_deletion

  # Remove exactly the mirrored item the deletion identifies (Req 5.1), and
  # nothing else. An album/artist is removed here only as the named target; any
  # further album/artist removal is governed solely by the deferred orphan
  # cleanup, which drops an album/artist iff no Mirrored_Song remains associated
  # with it (Req 5.2).
  #
  # This is why album/artist targets are removed with `delete` rather than
  # `destroy`: `Artist has_many :albums, dependent: :destroy` and
  # `Album has_many :songs, dependent: :destroy` would otherwise cascade-destroy
  # albums/songs that still belong to the item. That cascade both contradicts
  # Req 5.2 (it would remove an album that still has songs) and breaks
  # idempotence/convergence (Req 8.2, 8.3): a later upsert in the same set can
  # re-link a child onto the to-be-deleted parent, so on a second application
  # the deletion would cascade away rows that survived the first. Removing only
  # the named row leaves surviving children with a foreign key to the removed
  # row; because ids are AUTOINCREMENT the id is never reused, so the reference
  # resolves to nil deterministically, and a later upsert referencing the same
  # hosting-side id re-links it (see `ensure_album`/`upsert_song`).
  #
  # A Mirrored_Song has no dependent that outlives the mirror row, so it is
  # destroyed normally to keep its own `dependent: :destroy` cleanup.
  def remove_identified(record)
    record.is_a?(Song) ? record.destroy! : record.delete
  end
  private_class_method :remove_identified

  # Drop any album/artist left with no mirrored song after the whole change set
  # has been applied, reusing the exact orphan-cleanup semantics of
  # `Media.clean_up` scoped to this remote Library: an album/artist is removed
  # iff no song remains associated with it in this mirror (Req 5.2). Isolated in
  # its own savepoint and tolerant of failure so a cleanup error leaves orphans
  # for a later sync rather than aborting the apply (Req 5.4).
  def clean_up_orphans(library)
    ActiveRecord::Base.transaction(requires_new: true) do
      Media.clean_up(library_id: library.id)
    end
  rescue ActiveRecord::ActiveRecordError
    nil
  end
  private_class_method :clean_up_orphans

  # The mirrored row a deletion targets, looked up by its hosting-side id within
  # this mirror; nil when it is already absent (making deletion idempotent).
  def deletion_target(library, change)
    case change[:item_type].to_s
    when "song" then library.songs.find_by(remote_song_id: change[:id])
    when "album" then library.albums.find_by(remote_album_id: change[:id])
    when "artist" then library.artists.find_by(remote_artist_id: change[:id])
    end
  end
  private_class_method :deletion_target

  # --- Helpers --------------------------------------------------------------

  def song_name(value)
    value.presence || "Unknown Song"
  end
  private_class_method :song_name

  def album_name(value)
    value.presence || Album::UNKNOWN_NAME
  end
  private_class_method :album_name

  def artist_name(value)
    value.presence || Artist::UNKNOWN_NAME
  end
  private_class_method :artist_name

  def truthy(value)
    ActiveModel::Type::Boolean.new.cast(value) || false
  end
  private_class_method :truthy
end
