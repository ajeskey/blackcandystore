# frozen_string_literal: true

require "test_helper"

# Property-based test for Property 6 of the remote-library-mirror-sync feature.
#
# Design property (remote-library-mirror-sync, Property 6):
#   When a Full_Sync and a series of Incremental_Syncs each advance a
#   Library_Connection to the same Catalog_Version, THE resulting
#   Catalog_Mirrors SHALL be identical (Req 8.3, 4.4).
#
# Two independent Library_Connections reach two separate Remote_Libraries whose
# Hosting_Server exposes the *same* Catalog at the same final Catalog_Version V:
#
#   * Mirror A is reached by a single `CatalogSync.full_sync`, which reads the
#     host's current version (V) and browses the host's entire Catalog
#     (artists/albums/songs, paged) to rebuild the mirror in one shot.
#   * Mirror B is reached by a series of `CatalogSync.incremental_sync` calls.
#     Each call serves one page of Catalog_Changes that advances the connection's
#     Sync_Cursor one step (0→1→2→…→V). The union of those change pages
#     reproduces exactly the same Catalog A browses.
#
# Both paths go through the real `Federation::Client` HTTP surface, stubbed with
# WebMock on the hosting endpoints the drivers actually call
# (`GET /federation/libraries/:id/changes` and the browse endpoints), so the
# whole full_sync / incremental_sync driver — client construction from the
# connection's `server_base_url` + `grant_token`, pagination, the apply step,
# the transaction, and the cursor advance — is exercised end to end.
#
# The generated Catalog is host-faithful: every Mirrored_Album carries at least
# one Mirrored_Song and every Mirrored_Artist carries at least one song or
# album, so the orphan-cleanup that runs on a deletion never removes a real item
# (a songless album/artist could never exist in a scanned host Catalog). The
# incremental history additionally exercises deletion propagation by adding and
# then removing "phantom" items (hosting-side ids the browse Catalog never
# contains); after the phantom is deleted, orphan cleanup drops its phantom
# album/artist, so mirror B still converges to exactly the Catalog mirror A
# browses.
#
# The final assertion snapshots each mirror keyed by hosting-side identifier —
# every Mirrored_Song/Album/Artist with its metadata and its associations
# expressed through the associated row's hosting-side id (never the volatile
# local autoincrement id) — and asserts the two snapshots are identical, along
# with both connections landing on the same Sync_Cursor V in `fresh` state.
class FullIncrementalConvergencePropertyTest < ActiveSupport::TestCase
  # Small hosting-side id pools so the generated Catalog is compact but exercises
  # shared associations across items.
  ARTIST_IDS = 3
  ALBUM_IDS = 4
  SONG_IDS = 6

  # Hosting-side id floor for the incremental-only "phantom" churn items, kept
  # well clear of the real id pools so a phantom never collides with a real row.
  PHANTOM_BASE = 1000

  A_BASE_URL = "https://host-a.example.com"
  B_BASE_URL = "https://host-b.example.com"
  A_LIBRARY_ID = 100
  B_LIBRARY_ID = 200

  setup do
    @user = users(:admin)

    # Connection A + its Remote_Library: the Full_Sync target.
    @connection_a = LibraryConnection.create!(
      user: @user,
      server_base_url: A_BASE_URL,
      remote_library_id: A_LIBRARY_ID,
      grant_token: "grant-token-a",
      status: :active
    )
    @mirror_a = Library.create!(
      name: "Prop6-MirrorA-#{SecureRandom.hex(4)}",
      kind: :remote,
      owner: @user,
      library_connection: @connection_a
    )

    # Connection B + its Remote_Library: the Incremental_Sync target.
    @connection_b = LibraryConnection.create!(
      user: @user,
      server_base_url: B_BASE_URL,
      remote_library_id: B_LIBRARY_ID,
      grant_token: "grant-token-b",
      status: :active
    )
    @mirror_b = Library.create!(
      name: "Prop6-MirrorB-#{SecureRandom.hex(4)}",
      kind: :remote,
      owner: @user,
      library_connection: @connection_b
    )
  end

  # Feature: remote-library-mirror-sync, Property 6: Full and incremental syncs to the same version converge to identical mirrors
  test "a full sync and a series of incremental syncs to the same version converge to identical mirrors" do
    check_property(iterations: 100) do
      rng = self # Rantly instance

      # --- Generate a host-faithful Catalog ---------------------------------
      # Songs are the source of truth; albums are exactly the album ids songs
      # reference, and artists exactly the artist ids songs/albums reference, so
      # no album or artist is ever songless (a scanned host Catalog invariant).
      n_songs = rng.range(1, SONG_IDS)

      raw_songs = Array.new(n_songs) do |i|
        song_id = i + 1
        {
          id: song_id,
          album_id: rng.range(1, ALBUM_IDS),
          artist_id: rng.range(1, ARTIST_IDS),
          duration: rng.range(30, 300),
          tracknum: rng.range(1, 20),
          discnum: rng.range(1, 3)
        }
      end

      # Albums = album ids referenced by songs. Each album's artist is the artist
      # of one of its own songs, guaranteeing that artist also owns a song.
      album_ids = raw_songs.map { |s| s[:album_id] }.uniq.sort
      raw_albums = album_ids.map do |album_id|
        owning_song = raw_songs.find { |s| s[:album_id] == album_id }
        {
          id: album_id,
          artist_id: owning_song[:artist_id],
          year: rng.range(1960, 2024),
          genre: "genre-#{rng.range(1, 4)}"
        }
      end

      # Artists = artist ids referenced by any song or album.
      artist_ids = (raw_songs.map { |s| s[:artist_id] } + raw_albums.map { |a| a[:artist_id] }).uniq.sort
      raw_artists = artist_ids.map do |artist_id|
        { id: artist_id, is_various: rng.boolean }
      end

      # Optional phantom churn for the incremental path only: 0..2 lifecycles,
      # each an add-step followed later by a delete-step, netting to nothing.
      phantom_count = rng.range(0, 2)

      [ raw_artists, raw_albums, raw_songs, phantom_count, rng.range(1, 4) ]
    end.check do |(raw_artists, raw_albums, raw_songs, phantom_count, requested_chunks)|
      reset_state
      WebMock.reset!

      # Canonical browse rows (what the host's browse endpoints return) and the
      # matching upsert change hashes (what the changes-since feed returns). The
      # client transforms browse rows into the identical change shape apply
      # consumes, so both sync paths apply the exact same per-item data.
      artist_rows = raw_artists.map { |a| artist_row(a) }
      album_rows = raw_albums.map { |a| album_row(a) }
      song_rows = raw_songs.map { |s| song_row(s) }

      artist_changes = artist_rows.map { |r| upsert_change("artist", r) }
      album_changes = album_rows.map { |r| upsert_change("album", r) }
      song_changes = song_rows.map { |r| upsert_change("song", r) }

      # fetch_full_catalog applies artists, then albums, then songs; the
      # incremental history preserves that dependency order across its chunks.
      full_upserts = artist_changes + album_changes + song_changes

      # --- Build the incremental step history -------------------------------
      chunk_count = [ requested_chunks, full_upserts.length ].min
      steps = contiguous_chunks(full_upserts, chunk_count)

      phantom_count.times do |i|
        phantom = phantom_lifecycle(PHANTOM_BASE + i)
        steps << phantom[:add]
        steps << phantom[:remove]
      end

      final_version = steps.length

      # --- Stub Mirror A: single Full_Sync to version V ---------------------
      # Version read (fetch_catalog_version) issues changes_since(cursor=0).
      stub_changes(A_BASE_URL, A_LIBRARY_ID, cursor: 0, page: 1, version: final_version, changes: [])
      stub_browse(A_BASE_URL, A_LIBRARY_ID, "artists", artist_rows)
      stub_browse(A_BASE_URL, A_LIBRARY_ID, "albums", album_rows)
      stub_browse(A_BASE_URL, A_LIBRARY_ID, "songs", song_rows)

      CatalogSync.full_sync(@connection_a)

      # --- Stub + run Mirror B: incremental syncs 0→1→…→V -------------------
      steps.each_with_index do |step_changes, idx|
        cursor = idx
        version = idx + 1
        stub_changes(B_BASE_URL, B_LIBRARY_ID, cursor: cursor, page: 1, version: version, changes: step_changes)
        stub_changes(B_BASE_URL, B_LIBRARY_ID, cursor: cursor, page: 2, version: version, changes: [])
      end

      steps.length.times { CatalogSync.incremental_sync(@connection_b) }

      # --- Convergence assertions ------------------------------------------
      snapshot_a = snapshot_mirror(@mirror_a)
      snapshot_b = snapshot_mirror(@mirror_b)

      assert_equal snapshot_a, snapshot_b,
        "full sync and incremental syncs to the same version produced different mirrors"

      # Both paths adopt the same Catalog_Version as their Sync_Cursor and land
      # fresh (Req 4.3, 4.6, 8.3).
      assert_equal final_version, @connection_a.reload.sync_cursor
      assert_equal final_version, @connection_b.reload.sync_cursor
      assert_equal "fresh", @connection_a.sync_state
      assert_equal "fresh", @connection_b.sync_state
    end
  end

  private

  # Reset both mirrors to empty and both connections to their pre-sync cursor so
  # each iteration starts from a known baseline. Order (songs, albums, artists)
  # respects the association graph.
  def reset_state
    [ @mirror_a, @mirror_b ].each do |library|
      Song.where(library_id: library.id).delete_all
      Album.where(library_id: library.id).delete_all
      Artist.where(library_id: library.id).delete_all
    end

    [ @connection_a, @connection_b ].each do |connection|
      connection.update!(sync_cursor: 0, sync_state: "fresh", last_synced_at: nil)
    end
  end

  # --- Canonical item representations ----------------------------------------
  # Names are a canonical function of the hosting-side id, faithfully modelling a
  # real feed where a hosting id maps to one stable name.

  def artist_row(artist)
    { "id" => artist[:id], "name" => "artist-#{artist[:id]}", "is_various" => artist[:is_various] }
  end

  def album_row(album)
    {
      "id" => album[:id],
      "name" => "album-#{album[:id]}",
      "year" => album[:year],
      "genre" => album[:genre],
      "artist_id" => album[:artist_id],
      "artist_name" => "artist-#{album[:artist_id]}"
    }
  end

  def song_row(song)
    {
      "id" => song[:id],
      "name" => "song-#{song[:id]}",
      "duration" => song[:duration],
      "tracknum" => song[:tracknum],
      "discnum" => song[:discnum],
      "album_id" => song[:album_id],
      "album_name" => "album-#{song[:album_id]}",
      "artist_id" => song[:artist_id],
      "artist_name" => "artist-#{song[:artist_id]}"
    }
  end

  def upsert_change(item_type, row)
    { "change_type" => "upsert", "item_type" => item_type }.merge(row)
  end

  # An add-step (artist, album, song in dependency order) and a matching
  # delete-step for a single phantom whose ids never appear in the browse
  # Catalog, so deleting it cleans up its phantom album/artist without touching
  # any real row.
  def phantom_lifecycle(phantom_id)
    artist = { "id" => phantom_id, "name" => "artist-#{phantom_id}", "is_various" => false }
    album = {
      "id" => phantom_id, "name" => "album-#{phantom_id}", "year" => 2000, "genre" => "phantom",
      "artist_id" => phantom_id, "artist_name" => "artist-#{phantom_id}"
    }
    song = {
      "id" => phantom_id, "name" => "song-#{phantom_id}", "duration" => 100, "tracknum" => 1, "discnum" => 1,
      "album_id" => phantom_id, "album_name" => "album-#{phantom_id}",
      "artist_id" => phantom_id, "artist_name" => "artist-#{phantom_id}"
    }

    {
      add: [ upsert_change("artist", artist), upsert_change("album", album), upsert_change("song", song) ],
      remove: [ { "change_type" => "deletion", "item_type" => "song", "id" => phantom_id } ]
    }
  end

  # Split an ordered list into `count` contiguous chunks, preserving order so the
  # artist→album→song dependency ordering is never broken across steps.
  def contiguous_chunks(list, count)
    return [ list ] if count <= 1

    slice_size = (list.length / count.to_f).ceil
    list.each_slice(slice_size).to_a
  end

  # --- WebMock stubs ---------------------------------------------------------

  def stub_changes(base_url, library_id, cursor:, page:, version:, changes:)
    body = { "catalog_version" => version, "full_sync_required" => false, "changes" => changes }
    stub_request(:get, "#{base_url}/federation/libraries/#{library_id}/changes")
      .with(query: { "cursor" => cursor.to_s, "page" => page.to_s })
      .to_return(status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" })
  end

  # Stub a browse endpoint: page 1 returns the rows, page 2 returns an empty
  # array so `browse_all`'s paging loop terminates.
  def stub_browse(base_url, library_id, type, rows)
    stub_request(:get, "#{base_url}/federation/libraries/#{library_id}/#{type}")
      .with(query: { "page" => "1" })
      .to_return(status: 200, body: rows.to_json, headers: { "Content-Type" => "application/json" })
    stub_request(:get, "#{base_url}/federation/libraries/#{library_id}/#{type}")
      .with(query: { "page" => "2" })
      .to_return(status: 200, body: [].to_json, headers: { "Content-Type" => "application/json" })
  end

  # --- Mirror snapshot -------------------------------------------------------

  # Capture a mirror's content keyed by hosting-side identifier, with
  # associations expressed through the associated row's hosting-side id so two
  # mirrors built by different paths compare equal by identity, not by volatile
  # local autoincrement id. Sorting by hosting-side id makes it order-independent.
  def snapshot_mirror(library)
    songs = Song.where(library_id: library.id).map do |song|
      {
        remote_id: song.remote_song_id,
        name: song.name,
        duration: song.duration,
        tracknum: song.tracknum,
        discnum: song.discnum,
        album_remote_id: song.album&.remote_album_id,
        artist_remote_id: song.artist&.remote_artist_id
      }
    end.sort_by { |row| row[:remote_id] }

    albums = Album.where(library_id: library.id).map do |album|
      {
        remote_id: album.remote_album_id,
        name: album.name,
        year: album.year,
        genre: album.genre,
        artist_remote_id: album.artist&.remote_artist_id
      }
    end.sort_by { |row| row[:remote_id] }

    artists = Artist.where(library_id: library.id).map do |artist|
      {
        remote_id: artist.remote_artist_id,
        name: artist.name,
        various: artist.various
      }
    end.sort_by { |row| row[:remote_id] }

    { songs: songs, albums: albums, artists: artists }
  end
end
