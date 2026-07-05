# frozen_string_literal: true

require "test_helper"

# Unit tests for the CatalogSync failure/recovery branches that are not covered
# by the property tests (task 9.5). These exercise two specific requirement
# clauses of the remote-library-mirror-sync feature:
#
#   Req 10.2  While a Library_Connection's Sync_State is `stale`, the
#             Redeeming_Server SHALL continue to serve browsing from the
#             last-known Catalog_Mirror and SHALL surface the staleness rather
#             than presenting the mirror as fresh.
#
#   Req 10.4  When a synchronization that previously failed later succeeds, the
#             Redeeming_Server SHALL set the Sync_State to `fresh` and SHALL
#             bring the Catalog_Mirror to the Hosting_Server's current Catalog.
#
# The hosting Server is stubbed with WebMock at the Changes_Since_API HTTP
# boundary (mirroring test/models/federation/client_test.rb) so the real
# `Federation::Client` + `CatalogSync.incremental_sync` code paths run: a
# transport failure (Timeout/Unreachable) drives the `stale` branch, and a
# subsequent successful changes response drives the recovery to `fresh`.
class CatalogSyncTest < ActiveSupport::TestCase
  BASE_URL = "https://remote.example.com"
  REMOTE_LIBRARY_ID = 4242
  GRANT_TOKEN = "remote-bearer-token"
  CHANGES_URL = "#{BASE_URL}/federation/libraries/#{REMOTE_LIBRARY_ID}/changes"

  setup do
    @user = users(:admin)

    @connection = LibraryConnection.create!(
      user: @user,
      server_base_url: BASE_URL,
      remote_library_id: REMOTE_LIBRARY_ID,
      grant_token: GRANT_TOKEN,
      status: :active
    )
    @mirror = Library.create!(
      name: "CatalogSync-Mirror-#{SecureRandom.hex(4)}",
      kind: :remote,
      owner: @user,
      library_connection: @connection
    )
  end

  # Req 10.2: a `stale` connection (status still active) keeps serving its
  # last-known Catalog_Mirror for browsing and surfaces staleness instead of
  # presenting the mirror as fresh.
  test "a stale connection keeps serving its last-known mirror and surfaces staleness" do
    # Establish a last-known, successfully-synced mirror (Sync_State fresh, a
    # non-zero cursor) with browsable content.
    CatalogSync.apply(@connection, [
      artist_upsert(1, "artist-1"),
      album_upsert(1, "album-1", artist_id: 1),
      song_upsert(1, "song-1", album_id: 1, artist_id: 1),
      song_upsert(2, "song-2", album_id: 1, artist_id: 1)
    ])
    @connection.update!(sync_cursor: 5, sync_state: "fresh", last_synced_at: 1.hour.ago)

    before = mirror_song_remote_ids

    # The next scheduled sync attempt fails: the host does not respond within
    # the content timeout budget.
    stub_request(:get, CHANGES_URL)
      .with(query: {cursor: 5, page: 1})
      .to_timeout

    CatalogSync.incremental_sync(@connection)
    @connection.reload

    # Staleness is surfaced, NOT presented as fresh.
    assert_equal "stale", @connection.sync_state
    refute_equal "fresh", @connection.sync_state

    # The connection is still active, so the mirror remains browsable.
    assert @connection.active?, "a stale connection must remain active/browsable"

    # The last-known mirror is retained intact and still served by the local
    # browse scope (no round-trip): the same rows remain queryable.
    assert_equal before, mirror_song_remote_ids,
      "the last-known Catalog_Mirror must be retained intact while stale"
    assert Song.in_library(@mirror).exists?,
      "browsing a stale connection must still serve its last-known mirror content"
    assert_equal [1, 2], mirror_song_remote_ids

    # The Sync_Cursor is left unchanged by the failed attempt.
    assert_equal 5, @connection.sync_cursor
  end

  # Req 10.4: a synchronization that first fails and later succeeds sets
  # Sync_State to `fresh` and brings the Catalog_Mirror to the host's current
  # Catalog (with the cursor advanced to the adopted Catalog_Version).
  test "a previously-failed sync that later succeeds becomes fresh and matches the host catalog" do
    # A last-known mirror holding only song 1, at cursor 5.
    CatalogSync.apply(@connection, [
      artist_upsert(1, "artist-1"),
      album_upsert(1, "album-1", artist_id: 1),
      song_upsert(1, "song-1", album_id: 1, artist_id: 1)
    ])
    @connection.update!(sync_cursor: 5, sync_state: "fresh", last_synced_at: 2.hours.ago)

    # --- First attempt fails (transport failure) --------------------------
    failing_stub = stub_request(:get, CHANGES_URL)
      .with(query: {cursor: 5, page: 1})
      .to_timeout

    CatalogSync.incremental_sync(@connection)
    @connection.reload

    assert_equal "stale", @connection.sync_state
    assert_equal 5, @connection.sync_cursor, "a failed sync must not advance the cursor"
    assert_equal [1], mirror_song_remote_ids, "a failed sync must retain the last-known mirror"

    WebMock.reset!

    # --- Second attempt succeeds: host serves its current catalog ---------
    # The host's current Catalog is songs 1 and 2 (both under album 1 / artist
    # 1), at Catalog_Version 10.
    current_catalog = [
      artist_upsert(1, "artist-1"),
      album_upsert(1, "album-1", artist_id: 1),
      song_upsert(1, "song-1", album_id: 1, artist_id: 1),
      song_upsert(2, "song-2", album_id: 1, artist_id: 1)
    ]
    stub_request(:get, CHANGES_URL)
      .with(query: {cursor: 5, page: 1})
      .to_return(status: 200, body: {catalog_version: 10, full_sync_required: false, changes: current_catalog}.to_json)
    stub_request(:get, CHANGES_URL)
      .with(query: {cursor: 5, page: 2})
      .to_return(status: 200, body: {catalog_version: 10, full_sync_required: false, changes: []}.to_json)

    CatalogSync.incremental_sync(@connection)
    @connection.reload

    # Recovery: Sync_State returns to fresh and the completion time is recorded.
    assert_equal "fresh", @connection.sync_state
    assert_not_nil @connection.last_synced_at

    # The cursor advances to the adopted Catalog_Version.
    assert_equal 10, @connection.sync_cursor

    # The mirror now matches the host's current Catalog by hosting-side id.
    assert_equal [1, 2], mirror_song_remote_ids
    assert_equal [1], mirror_album_remote_ids
    assert_equal [1], mirror_artist_remote_ids
  end

  private

  def mirror_song_remote_ids
    Song.in_library(@mirror).pluck(:remote_song_id).sort
  end

  def mirror_album_remote_ids
    Album.in_library(@mirror).pluck(:remote_album_id).sort
  end

  def mirror_artist_remote_ids
    Artist.in_library(@mirror).pluck(:remote_artist_id).sort
  end

  def artist_upsert(id, name, is_various: false)
    {"change_type" => "upsert", "item_type" => "artist", "id" => id, "name" => name, "is_various" => is_various}
  end

  def album_upsert(id, name, artist_id:)
    {
      "change_type" => "upsert", "item_type" => "album", "id" => id, "name" => name,
      "year" => 2020, "genre" => "genre-1", "artist_id" => artist_id, "artist_name" => "artist-#{artist_id}"
    }
  end

  def song_upsert(id, name, album_id:, artist_id:)
    {
      "change_type" => "upsert", "item_type" => "song", "id" => id, "name" => name,
      "duration" => 200, "tracknum" => 1, "discnum" => 1,
      "album_id" => album_id, "album_name" => "album-#{album_id}",
      "artist_id" => artist_id, "artist_name" => "artist-#{artist_id}"
    }
  end
end
