# frozen_string_literal: true

require "test_helper"

# Property-based test for Property 4 of the remote-library-mirror-sync feature.
#
# Design property (remote-library-mirror-sync, Property 4):
#   A successful sync converges the Catalog_Mirror to the Hosting_Server's
#   Catalog at the adopted Catalog_Version: after the sync the mirror equals the
#   host Catalog by hosting-side identifier (same songs/albums/artists, every
#   association preserved, no absent item remaining and no extra item), the
#   Sync_Cursor equals the adopted Catalog_Version, the Sync_State is `fresh`,
#   and Last_Synced_At is recorded
#   (Req 1.6, 2.5, 4.3, 4.6, 5.3, 8.1, 8.4, 10.4).
#
# `CatalogSync.full_sync(connection)` is the successful-sync driver under test.
# It fetches the Hosting_Server's current Catalog over the Federation API
# (`Federation::Client#changes_since` for the version, then `#browse` for the
# paged songs/albums/artists), rebuilds the Catalog_Mirror to exactly that set
# by hosting-side id (removing anything absent), adopts the current
# Catalog_Version as the Sync_Cursor, sets Sync_State to `fresh`, and stamps
# Last_Synced_At — all in a single transaction.
#
# The network is not exercised: `Federation::Client.new` is stubbed per
# iteration with a fake client that serves a generated host Catalog (a
# catalog_version plus artist/album/song browse rows), so the sync converges
# against a known target without a live peer. Each iteration first materializes
# an ARBITRARY starting mirror (stale rows plus extra rows the host no longer
# has) by applying an independently generated change set, so the sync must both
# add/update the host's items AND drop the extras to converge.
#
# Names are a canonical function of the hosting-side id ("Artist #{id}",
# "Album #{id}", "Song #{id}"): the mirror's per-library unique name indexes
# (`artists (library_id, name)`, `albums (library_id, artist_id, name)`) mean a
# hosting-side id must map to a stable name, exactly as the host scanner emits.
# Both the starting mirror and the host Catalog use the same scheme so a shared
# id always reuses the same row (keyed on `(library_id, remote_*_id)`) rather
# than colliding on a name.
class SuccessfulSyncConvergencePropertyTest < ActiveSupport::TestCase
  # A fake Federation::Client that serves a fixed host Catalog. It answers the
  # exact two calls `full_sync` makes: `changes_since` (only its
  # `catalog_version` is read to learn the version to adopt) and the paged
  # `browse` for each content type. Everything is served on page 1; page 2 comes
  # back empty, ending `browse_all`'s pagination loop.
  class StubHostCatalogClient
    def initialize(catalog_version:, artist_rows:, album_rows:, song_rows:)
      @catalog_version = catalog_version
      @rows = { "artists" => artist_rows, "albums" => album_rows, "songs" => song_rows }
    end

    def changes_since(_library_id, _cursor, _page = 1)
      { "catalog_version" => @catalog_version, "full_sync_required" => false, "changes" => [] }
    end

    def browse(_library_id, type, params = {})
      page = (params[:page] || params["page"] || 1).to_i
      page == 1 ? @rows.fetch(type.to_s, []) : []
    end
  end

  setup do
    @user = users(:admin)
    @seq = 0
  end

  # Feature: remote-library-mirror-sync, Property 4: A successful sync converges the mirror to the host catalog at the adopted version
  test "a successful full sync converges the mirror to the host catalog by hosting-side id, adopts the version, and marks it fresh" do
    check_property(iterations: 100) do
      rng = self # Rantly instance

      # The Hosting_Server's current Catalog, described purely by hosting-side
      # ids. Artists may be song-less, albums may be song-less, and every song
      # references an existing album whose artist it shares — the shape a real
      # host scanner produces. The mirror must end up equal to exactly this set.
      host_artist_ids = (1..rng.range(1, 4)).to_a
      host_albums = Array.new(rng.range(1, 5)) do |i|
        { id: i + 1, artist_id: host_artist_ids[rng.range(0, host_artist_ids.size - 1)] }
      end
      host_songs = Array.new(rng.range(1, 8)) do |i|
        album = host_albums[rng.range(0, host_albums.size - 1)]
        { id: i + 1, album_id: album[:id], artist_id: album[:artist_id] }
      end

      catalog_version = rng.range(1, 100_000)

      # An arbitrary STARTING mirror: upserts over a broader id pool (1..10) so
      # it holds a mix of ids the host still has (stale rows to update) and ids
      # the host no longer has (extras the sync must drop). Referenced
      # album/artist ids that lack their own upsert are auto-created by apply,
      # so this need not be internally consistent to be a valid prior mirror.
      base_artist_ids = (1..rng.range(0, 10)).to_a
      base_albums = Array.new(rng.range(0, 10)) do |i|
        { id: i + 1, artist_id: rng.range(1, 10) }
      end
      base_songs = Array.new(rng.range(0, 12)) do |i|
        { id: i + 1, album_id: rng.range(1, 10), artist_id: rng.range(1, 10) }
      end

      [
        { artist_ids: host_artist_ids, albums: host_albums, songs: host_songs },
        catalog_version,
        { artist_ids: base_artist_ids, albums: base_albums, songs: base_songs }
      ]
    end.check do |(host, catalog_version, base)|
      connection, library = fresh_mirror

      # Establish the arbitrary starting mirror (may hold extras and stale rows).
      CatalogSync.apply(connection, upsert_changes(base))

      client = StubHostCatalogClient.new(
        catalog_version: catalog_version,
        artist_rows: artist_rows(host),
        album_rows: album_rows(host),
        song_rows: song_rows(host)
      )

      # Run the successful sync against the stubbed host Catalog.
      Federation::Client.stub(:new, client) do
        CatalogSync.full_sync(connection)
      end

      connection.reload
      library.reload

      # --- Sync bookkeeping (Req 1.6, 4.3, 4.6, 10.4) -----------------------
      assert_equal catalog_version, connection.sync_cursor,
        "the Sync_Cursor must equal the adopted Catalog_Version"
      assert_equal "fresh", connection.sync_state,
        "a successful sync must mark the Sync_State fresh"
      assert_not_nil connection.last_synced_at,
        "a successful sync must record Last_Synced_At"

      # --- Membership: mirror == host Catalog by hosting-side id ------------
      # No item absent from the host Catalog remains, and no extra item exists
      # (Req 5.3, 8.1, 8.4).
      expected_artist_ids = host[:artist_ids].uniq.sort
      expected_album_ids = host[:albums].map { |a| a[:id] }.uniq.sort
      expected_song_ids = host[:songs].map { |s| s[:id] }.uniq.sort

      assert_equal expected_artist_ids, library.artists.pluck(:remote_artist_id).sort,
        "mirror artists must equal the host catalog by hosting-side id"
      assert_equal expected_album_ids, library.albums.pluck(:remote_album_id).sort,
        "mirror albums must equal the host catalog by hosting-side id"
      assert_equal expected_song_ids, library.songs.pluck(:remote_song_id).sort,
        "mirror songs must equal the host catalog by hosting-side id"

      # --- Associations preserved (Req 2.5, 8.1) ---------------------------
      album_artist = host[:albums].to_h { |a| [ a[:id], a[:artist_id] ] }
      song_album = host[:songs].to_h { |s| [ s[:id], s[:album_id] ] }
      song_artist = host[:songs].to_h { |s| [ s[:id], s[:artist_id] ] }

      library.albums.each do |album|
        assert_equal album_artist[album.remote_album_id], album.artist.remote_artist_id,
          "album #{album.remote_album_id} must link the artist carrying the matching hosting id"
        assert_equal library.id, album.artist.library_id,
          "album #{album.remote_album_id} must link an artist scoped to the same mirror"
      end

      library.songs.each do |song|
        assert_equal song_album[song.remote_song_id], song.album.remote_album_id,
          "song #{song.remote_song_id} must link the album carrying the matching hosting id"
        assert_equal song_artist[song.remote_song_id], song.artist.remote_artist_id,
          "song #{song.remote_song_id} must link the artist carrying the matching hosting id"
        assert_equal library.id, song.library_id
        assert_equal library.id, song.album.library_id,
          "song #{song.remote_song_id} must link an album scoped to the same mirror"
        assert_equal library.id, song.artist.library_id,
          "song #{song.remote_song_id} must link an artist scoped to the same mirror"
      end
    end
  end

  private

  # A fresh active Library_Connection + its remote Library (the Catalog_Mirror),
  # isolated per iteration so convergence is asserted only over this run's data.
  def fresh_mirror
    @seq += 1
    connection = LibraryConnection.create!(
      user: @user,
      server_base_url: "https://host.example.com",
      remote_library_id: @seq,
      grant_token: "grant-token-#{@seq}",
      status: :active
    )
    library = Library.create!(
      name: "Prop4-Mirror-#{SecureRandom.hex(6)}",
      kind: :remote,
      owner: @user,
      library_connection: connection
    )
    [ connection, library ]
  end

  # --- host Catalog -> browse rows (the wire shape `full_sync` consumes) -----

  def artist_rows(catalog)
    catalog[:artist_ids].map do |id|
      { "id" => id, "name" => "Artist #{id}", "is_various" => false }
    end
  end

  def album_rows(catalog)
    catalog[:albums].map do |album|
      {
        "id" => album[:id], "name" => "Album #{album[:id]}",
        "year" => 2000, "genre" => "Rock",
        "artist_id" => album[:artist_id], "artist_name" => "Artist #{album[:artist_id]}"
      }
    end
  end

  def song_rows(catalog)
    catalog[:songs].map do |song|
      {
        "id" => song[:id], "name" => "Song #{song[:id]}",
        "duration" => 123.0, "tracknum" => 1, "discnum" => 1,
        "album_id" => song[:album_id], "album_name" => "Album #{song[:album_id]}",
        "artist_id" => song[:artist_id], "artist_name" => "Artist #{song[:artist_id]}"
      }
    end
  end

  # --- catalog -> upsert Catalog_Changes (to seed the arbitrary base mirror) -

  def upsert_changes(catalog)
    changes = []

    catalog[:artist_ids].each do |id|
      changes << {
        "change_type" => "upsert", "item_type" => "artist", "id" => id,
        "name" => "Artist #{id}", "is_various" => false
      }
    end

    catalog[:albums].each do |album|
      changes << {
        "change_type" => "upsert", "item_type" => "album", "id" => album[:id],
        "name" => "Album #{album[:id]}", "year" => 1999, "genre" => "Jazz",
        "artist_id" => album[:artist_id], "artist_name" => "Artist #{album[:artist_id]}"
      }
    end

    catalog[:songs].each do |song|
      changes << {
        "change_type" => "upsert", "item_type" => "song", "id" => song[:id],
        "name" => "Song #{song[:id]}", "duration" => 200.0, "tracknum" => 2, "discnum" => 1,
        "album_id" => song[:album_id], "album_name" => "Album #{song[:album_id]}",
        "artist_id" => song[:artist_id], "artist_name" => "Artist #{song[:artist_id]}"
      }
    end

    changes
  end
end
