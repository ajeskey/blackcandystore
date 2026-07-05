# frozen_string_literal: true

require "test_helper"

# Property-based test for Property 10 of the remote-library-mirror-sync feature.
#
# Design property (remote-library-mirror-sync, Property 10):
#   A failed sync retains the mirror and cursor and marks it stale. If the
#   Hosting_Server is unreachable or times out during a synchronization, the
#   Redeeming_Server SHALL retain the last-known Catalog_Mirror intact, leave
#   the Sync_Cursor unchanged, and set the Sync_State to `stale` (Req 10.1). If
#   a synchronization fails partway through applying Catalog_Changes, the
#   Redeeming_Server SHALL NOT leave the Catalog_Mirror partially updated with
#   an advanced Sync_Cursor (Req 10.3).
#
# `CatalogSync.full_sync` / `CatalogSync.incremental_sync` drive a sync: they
# fetch over the Federation API, then apply the delta and advance the cursor
# inside a single `ActiveRecord::Base.transaction`. A transport failure happens
# *before* the transaction opens, so it is caught and the connection is marked
# `stale` with the mirror and cursor untouched. A mid-apply failure raises
# *inside* the transaction, which rolls the whole apply and the cursor advance
# back, so the mirror is never left partially updated.
#
# Each iteration:
#   1. materializes an arbitrary starting Catalog_Mirror by applying a randomly
#      generated upsert set, and records a "successful" pre-sync state
#      (sync_state `fresh`, an arbitrary Sync_Cursor, a Last_Synced_At);
#   2. snapshots the mirror (every Mirrored_Song/Album/Artist keyed by its
#      hosting-side id together with metadata and associations expressed through
#      hosting-side ids), the cursor, and the sync_state;
#   3. induces a failure one of two ways —
#        (a) TRANSPORT: stub the changes-since endpoint to time out or to refuse
#            the connection (WebMock `.to_timeout` / `.to_raise(ECONNREFUSED)`),
#            driving both `incremental_sync` and `full_sync`; or
#        (b) MID-APPLY: let the fetch succeed, then make the apply step mutate a
#            row and raise partway so the surrounding transaction must roll back;
#   4. asserts the mirror is byte-for-byte its pre-sync snapshot, the Sync_Cursor
#      is unchanged, and — for transport failures — the Sync_State is `stale`;
#      for a propagating mid-apply raise it asserts the transaction rolled back
#      (cursor unchanged, mirror unchanged, sync_state uncorrupted), so the
#      mirror is never left partially updated with an advanced cursor.
class FailedSyncRetentionPropertyTest < ActiveSupport::TestCase
  REMOTE_LIBRARY_ID = 4242
  BASE_URL = "https://remote.example.com"
  CHANGES_URL = %r{\Ahttps://remote\.example\.com/federation/libraries/\d+/changes}
  BROWSE_URL = %r{\Ahttps://remote\.example\.com/federation/libraries/\d+/(artists|albums|songs)}

  # A sentinel hosting-side id for the row a mid-apply failure mutates before it
  # raises; it must survive only if the transaction wrongly commits.
  PARTIAL_ARTIST_REMOTE_ID = 9_000_000

  MODES = %i[
    incremental_timeout incremental_econnrefused
    full_timeout full_econnrefused
    incremental_midapply full_midapply
  ].freeze

  setup do
    @user = users(:admin)

    @connection = LibraryConnection.create!(
      user: @user,
      server_base_url: BASE_URL,
      remote_library_id: REMOTE_LIBRARY_ID,
      grant_token: "remote-bearer-token",
      status: :active
    )
    @mirror = Library.create!(
      name: "Prop10-Mirror-#{SecureRandom.hex(4)}",
      kind: :remote,
      owner: @user,
      library_connection: @connection
    )
  end

  # Feature: remote-library-mirror-sync, Property 10: A failed sync retains the mirror and cursor and marks it stale
  test "a failed sync leaves the mirror and cursor unchanged and marks the connection stale" do
    check_property(iterations: 100) do
      rng = self # Rantly instance

      # Build an ordered upsert set over small shared hosting-side id pools so
      # the starting mirror has related artists/albums/songs.
      build_base = lambda do
        n_artists = rng.range(1, 3)
        n_albums = rng.range(1, 4)
        n_songs = rng.range(1, 6)

        changes = []

        (1..n_artists).each do |aid|
          changes << {
            "change_type" => "upsert", "item_type" => "artist", "id" => aid,
            "name" => "artist-#{aid}", "is_various" => rng.boolean
          }
        end

        album_artist = {}
        (1..n_albums).each do |alid|
          artist_id = rng.range(1, n_artists)
          album_artist[alid] = artist_id
          changes << {
            "change_type" => "upsert", "item_type" => "album", "id" => alid,
            "name" => "album-#{alid}", "year" => rng.range(1960, 2024),
            "genre" => "genre-#{rng.range(1, 4)}",
            "artist_id" => artist_id, "artist_name" => "artist-#{artist_id}"
          }
        end

        (1..n_songs).each do |sid|
          album_id = rng.range(1, n_albums)
          artist_id = album_artist[album_id]
          changes << {
            "change_type" => "upsert", "item_type" => "song", "id" => sid,
            "name" => "song-#{sid}", "duration" => rng.range(30, 300),
            "tracknum" => rng.range(1, 20), "discnum" => rng.range(1, 3),
            "album_id" => album_id, "album_name" => "album-#{album_id}",
            "artist_id" => artist_id, "artist_name" => "artist-#{artist_id}"
          }
        end

        changes
      end

      [ build_base.call, rng.range(1, 100), rng.choose(*MODES) ]
    end.check do |(base_changes, starting_cursor, mode)|
      reset_mirror

      # Establish an arbitrary starting Catalog_Mirror and a "last sync
      # succeeded" state: fresh, at an arbitrary cursor, with a Last_Synced_At.
      CatalogSync.apply(@connection, base_changes)
      @connection.update!(
        sync_cursor: starting_cursor,
        sync_state: "fresh",
        last_synced_at: Time.current
      )

      @pre_cursor = @connection.sync_cursor
      @pre_state = @connection.sync_state
      @pre_snapshot = snapshot_mirror
      # A version strictly ahead of the cursor, so a (wrongly) committed sync
      # would be detectable as an advanced cursor.
      @catalog_version = @pre_cursor + 10

      run_failed_sync(mode)

      # Regardless of failure kind: the mirror is exactly its pre-sync snapshot
      # and the Sync_Cursor never advanced (Req 10.1, 10.3).
      @connection.reload
      assert_equal @pre_cursor, @connection.sync_cursor,
        "[#{mode}] Sync_Cursor advanced across a failed sync"
      assert_equal @pre_snapshot, snapshot_mirror,
        "[#{mode}] the Catalog_Mirror was not retained intact across a failed sync"

      if transport_mode?(mode)
        # Req 10.1: a transport failure marks the mirror stale (and keeps serving).
        assert_equal "stale", @connection.sync_state,
          "[#{mode}] a transport failure should mark the connection stale"
      else
        # Req 10.3: a mid-apply raise rolls back, leaving the pre-sync state
        # uncorrupted — no partial mirror, no advanced cursor.
        assert_equal @pre_state, @connection.sync_state,
          "[#{mode}] a rolled-back mid-apply failure should not corrupt sync_state"
      end
    end
  end

  private

  def transport_mode?(mode)
    %i[incremental_timeout incremental_econnrefused full_timeout full_econnrefused].include?(mode)
  end

  # Set up the stubs for a failure mode and drive the matching sync. Transport
  # failures are swallowed by the driver (mark stale); mid-apply failures
  # propagate and MUST roll the transaction back.
  def run_failed_sync(mode)
    case mode
    when :incremental_timeout
      stub_changes(:timeout)
      CatalogSync.incremental_sync(@connection)
    when :incremental_econnrefused
      stub_changes(:econnrefused)
      CatalogSync.incremental_sync(@connection)
    when :full_timeout
      stub_changes(:timeout)
      CatalogSync.full_sync(@connection)
    when :full_econnrefused
      stub_changes(:econnrefused)
      CatalogSync.full_sync(@connection)
    when :incremental_midapply
      stub_changes(:ok)
      assert_raises(RuntimeError) do
        with_failing_apply { CatalogSync.incremental_sync(@connection) }
      end
    when :full_midapply
      stub_changes(:ok)
      stub_browse_empty
      assert_raises(RuntimeError) do
        with_failing_apply { CatalogSync.full_sync(@connection) }
      end
    end
  end

  # Stub the changes-since endpoint. `:timeout` / `:econnrefused` induce the
  # transport failures the driver maps to Timeout / Unreachable; `:ok` returns a
  # well-formed empty delta (every page empty) so the fetch succeeds and control
  # reaches the transactional apply, where the failure is injected instead.
  def stub_changes(kind)
    case kind
    when :timeout
      stub_request(:get, CHANGES_URL).to_timeout
    when :econnrefused
      stub_request(:get, CHANGES_URL).to_raise(Errno::ECONNREFUSED)
    when :ok
      stub_request(:get, CHANGES_URL).to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { catalog_version: @catalog_version, full_sync_required: false, changes: [] }.to_json
      )
    end
  end

  # Full_Sync pages the host catalog before opening its transaction; an empty
  # browse lets the fetch complete so the mid-apply failure is what fails.
  def stub_browse_empty
    stub_request(:get, BROWSE_URL).to_return(
      status: 200,
      headers: { "Content-Type" => "application/json" },
      body: [].to_json
    )
  end

  # Replace the apply step so it mutates the mirror (creating a row that must be
  # rolled back) and then raises partway, exactly as a database error or
  # concurrent change would abort an apply in flight (Req 10.3).
  def with_failing_apply
    CatalogSync.stub(:apply, ->(_connection, _changes) do
      @mirror.artists.create!(name: "partial-orphan", remote_artist_id: PARTIAL_ARTIST_REMOTE_ID)
      raise "mid-apply failure injected"
    end) do
      yield
    end
  end

  # Empty the Catalog_Mirror so each iteration starts from a known baseline.
  def reset_mirror
    Song.where(library_id: @mirror.id).delete_all
    Album.where(library_id: @mirror.id).delete_all
    Artist.where(library_id: @mirror.id).delete_all
  end

  # Capture the mirror keyed by hosting-side identifier, with associations
  # expressed through the associated row's hosting-side id (never the volatile
  # local autoincrement id). Sorting makes the comparison order-independent.
  def snapshot_mirror
    songs = Song.where(library_id: @mirror.id).map do |song|
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

    albums = Album.where(library_id: @mirror.id).map do |album|
      {
        remote_id: album.remote_album_id,
        name: album.name,
        year: album.year,
        genre: album.genre,
        artist_remote_id: album.artist&.remote_artist_id
      }
    end.sort_by { |row| row[:remote_id] }

    artists = Artist.where(library_id: @mirror.id).map do |artist|
      {
        remote_id: artist.remote_artist_id,
        name: artist.name,
        various: artist.various
      }
    end.sort_by { |row| row[:remote_id] }

    { songs: songs, albums: albums, artists: artists }
  end
end
