# frozen_string_literal: true

require "test_helper"

# Property-based test for Property 11 of the remote-library-mirror-sync feature.
#
# Design property (remote-library-mirror-sync, Property 11):
#   For any set of Library_Connections with Catalog_Mirrors, tearing down one
#   connection — because a synchronization was rejected with an authorization
#   error (mirror removed or marked unavailable, Sync_State `unavailable`),
#   because its status became revoked or unavailable (no longer served for
#   browsing, searching, or listing), or because the connection was deleted
#   (mirror removed in full) — SHALL leave every other Library_Connection's
#   Catalog_Mirror unchanged and still browsable (Req 9.1, 9.2, 9.3, 9.5).
#
# The test materializes several Remote_Library Catalog_Mirrors (each an
# independent Library_Connection owned by the same User, holding mirrored
# artists/albums/songs whose hosting-side id values deliberately OVERLAP across
# connections so the per-`library_id` scoping is exercised, not just distinct
# id spaces). It then tears exactly one connection down via one of the three
# real teardown paths and asserts locality:
#
#   (a) authorization error — the hosting Server refuses `changes_since` with a
#       403; `Federation::Client` maps it to `Unauthorized` and
#       `CatalogSync.incremental_sync` runs its teardown branch, marking the
#       connection `revoked` / `sync_state: unavailable` so the mirror is no
#       longer browsable (rows retained but hidden) (Req 9.1, 9.4);
#   (b) status transition — the connection status becomes `revoked` or
#       `unavailable`, so its mirror stops being served for browse/search/list
#       (rows retained but hidden) (Req 9.2);
#   (c) deletion — the LibraryConnection is destroyed, so its remote Library and
#       every Mirrored_Song/Album/Artist is removed in full (Req 9.3).
#
# For the torn-down connection it asserts the mirror is removed (deletion) or
# hidden and marked appropriately (auth-error/status). For EVERY OTHER
# connection it asserts the mirror rows are byte-for-byte the same set as before
# the teardown AND that the mirror is still browsable — the library is still in
# the User's authorized `active_remote_libraries` set (the single browse-scope
# enforcement point named by the design) and every one of its Mirrored_Songs is
# still `RemoteAvailability.available?` (Req 9.5).
class TeardownLocalityPropertyTest < ActiveSupport::TestCase
  # The three teardown paths of Req 9.1/9.2/9.3.
  TEARDOWN_PATHS = %i[auth_error revoked unavailable deletion].freeze
  # Paths that HIDE the mirror (rows retained, connection non-active) rather
  # than DELETE it.
  HIDE_PATHS = %i[auth_error revoked unavailable].freeze

  setup do
    @user = users(:visitor1)
    @seq = 0
  end

  # Feature: remote-library-mirror-sync, Property 11: Teardown removes or hides only the affected connection's mirror
  test "tearing down one connection removes or hides only its mirror and leaves every other connection's mirror unchanged and browsable" do
    paths = TEARDOWN_PATHS

    check_property(iterations: 100) do
      connection_count = range(2, 4)
      # Per-connection catalog shape: a list of artists, each artist a list of
      # albums, each album a song count (>= 1). Pure data, no DB side effects.
      catalogs = Array.new(connection_count) do
        artist_count = range(1, 2)
        Array.new(artist_count) do
          album_count = range(1, 2)
          Array.new(album_count) { range(1, 3) }
        end
      end

      target_index = range(0, connection_count - 1)
      path = paths[range(0, paths.size - 1)]

      [ catalogs, target_index, path ]
    end.check do |(catalogs, target_index, path)|
      # Isolate each iteration from fixtures and the previous run so the
      # authorized-set and availability assertions are computed only over this
      # iteration's generated mirrors.
      reset_world

      mirrors = catalogs.map { |catalog_spec| build_connection_with_mirror(catalog_spec) }
      target = mirrors[target_index]
      others = mirrors.reject.with_index { |_, i| i == target_index }

      # Snapshot every mirror's content (by hosting-side id) BEFORE teardown so
      # the "unchanged" assertion compares against the pre-teardown picture.
      before = mirrors.to_h { |m| [ m[:connection].id, mirror_snapshot(m[:library]) ] }

      # Sanity: before teardown every connection is active and browsable.
      browsable_ids = @user.active_remote_libraries.ids
      mirrors.each do |m|
        assert_includes browsable_ids, m[:library].id,
          "expected every mirror to be browsable before teardown"
      end

      tear_down(target, path)

      # --- The torn-down connection --------------------------------------
      if path == :deletion
        # (c) The mirror is removed in full: the remote Library and all of its
        # mirrored content are gone (Req 9.3).
        assert_not LibraryConnection.exists?(target[:connection].id),
          "a deleted connection must be removed"
        assert_not Library.exists?(target[:library].id),
          "a deleted connection's remote Library must be removed"
        assert_equal 0, Song.where(library_id: target[:library].id).count,
          "every Mirrored_Song of a deleted connection must be removed"
        assert_equal 0, Album.where(library_id: target[:library].id).count,
          "every Mirrored_Album of a deleted connection must be removed"
        assert_equal 0, Artist.where(library_id: target[:library].id).count,
          "every Mirrored_Artist of a deleted connection must be removed"
      else
        target[:connection].reload

        # (a)/(b) The mirror is hidden: the connection is no longer active, so
        # it drops out of the browsable authorized set and its songs report
        # unavailable — but the rows are retained, not deleted (Req 9.1, 9.2).
        assert_not target[:connection].active?,
          "a torn-down connection (#{path}) must no longer be active"
        assert_not_includes @user.active_remote_libraries.ids, target[:library].id,
          "a hidden mirror (#{path}) must not be browsable"
        target[:library].songs.each do |song|
          assert_not RemoteAvailability.available?(song),
            "a hidden mirror's songs (#{path}) must be unavailable"
        end
        assert_equal before[target[:connection].id], mirror_snapshot(target[:library]),
          "a hidden mirror (#{path}) must retain its rows rather than delete them"

        if path == :auth_error
          # Req 9.1/9.4: an authorization rejection sets Sync_State unavailable.
          assert_equal "unavailable", target[:connection].sync_state,
            "an auth-error teardown must set sync_state to unavailable"
        end
      end

      # --- Every other connection: unchanged and still browsable ----------
      browsable_after = @user.active_remote_libraries.ids
      others.each do |m|
        m[:connection].reload

        assert_equal before[m[:connection].id], mirror_snapshot(m[:library]),
          "an untouched connection's mirror must be byte-for-byte unchanged after teardown"

        assert m[:connection].active?,
          "an untouched connection must remain active"
        assert_equal "fresh", m[:connection].sync_state,
          "an untouched connection's sync_state must be unchanged"

        assert_includes browsable_after, m[:library].id,
          "an untouched connection's mirror must remain browsable"

        m[:library].songs.each do |song|
          assert RemoteAvailability.available?(song),
            "an untouched connection's mirrored songs must remain available"
        end
      end
    end
  end

  private

  def next_seq
    @seq += 1
  end

  # Start each iteration from an empty content/connection/library set. delete_all
  # skips callbacks, which is safe because content is cleared before its
  # containers.
  def reset_world
    WebMock.reset!
    Song.delete_all
    Album.delete_all
    Artist.delete_all
    Library.delete_all
    LibraryConnection.delete_all
  end

  # Materialize one Library_Connection + Remote_Library Catalog_Mirror from a
  # catalog shape and return the connection, its mirror Library, and the
  # host base URL / remote library id needed to stub the auth-error path.
  #
  # The mirror is built by driving the real `CatalogSync.apply` engine with the
  # same upsert change shape the Changes_Since feed produces, so the rows carry
  # the hosting-side ids and associations exactly as a live sync would.
  def build_connection_with_mirror(catalog_spec)
    n = next_seq
    base_url = "https://host#{n}.example"
    remote_library_id = n

    connection = LibraryConnection.create!(
      user: @user,
      server_base_url: base_url,
      remote_library_id: remote_library_id,
      grant_token: "token-#{n}",
      status: :active,
      sync_state: "fresh",
      sync_cursor: 1
    )
    library = Library.create!(
      name: "Prop11-Mirror-#{SecureRandom.hex(6)}",
      kind: :remote,
      library_connection: connection
    )
    # Ensure the has_one association resolves for CatalogSync.apply.
    connection.reload

    CatalogSync.apply(connection, build_changes(catalog_spec))

    {
      connection: connection,
      library: library,
      base_url: base_url,
      remote_library_id: remote_library_id
    }
  end

  # Turn a catalog shape (list of artists -> albums -> song count) into an
  # ordered upsert change set. Hosting-side ids are assigned within this
  # connection starting from 1, so id VALUES overlap across connections and the
  # per-`library_id` scoping is genuinely exercised.
  def build_changes(catalog_spec)
    changes = []
    artist_id = 0
    album_id = 0
    song_id = 0

    catalog_spec.each do |albums_spec|
      artist_id += 1
      current_artist = artist_id
      changes << artist_upsert(current_artist, "artist-#{current_artist}")

      albums_spec.each do |song_count|
        album_id += 1
        current_album = album_id
        changes << album_upsert(current_album, "album-#{current_album}", artist_id: current_artist)

        song_count.times do
          song_id += 1
          changes << song_upsert(song_id, "song-#{song_id}", album_id: current_album, artist_id: current_artist)
        end
      end
    end

    changes
  end

  # Tear one connection down via the requested real path.
  def tear_down(target, path)
    case path
    when :auth_error
      # The hosting Server refuses synchronization with a 403; the client maps
      # it to Unauthorized and incremental_sync runs its teardown branch.
      changes_url = "#{target[:base_url]}/federation/libraries/#{target[:remote_library_id]}/changes"
      stub_request(:get, changes_url).with(query: hash_including({})).to_return(status: 403)
      CatalogSync.incremental_sync(target[:connection])
    when :revoked, :unavailable
      target[:connection].update!(status: path)
    when :deletion
      target[:connection].destroy!
    end
  end

  # A stable, comparable snapshot of a mirror's content by hosting-side id and
  # associations, so "unchanged" can be asserted by equality. Album/song rows
  # store their artist/album links by local id, so the association is captured
  # through the joined row's hosting-side id to make the snapshot stable across
  # the create-or-find id churn a re-sync could introduce.
  def mirror_snapshot(library)
    {
      artists: Artist.where(library_id: library.id).order(:remote_artist_id).pluck(:remote_artist_id, :name),
      albums: Album.where(library_id: library.id)
        .joins("LEFT JOIN artists ON artists.id = albums.artist_id")
        .order(:remote_album_id)
        .pluck(:remote_album_id, "albums.name", "artists.remote_artist_id"),
      songs: Song.where(library_id: library.id)
        .joins("LEFT JOIN albums ON albums.id = songs.album_id")
        .joins("LEFT JOIN artists ON artists.id = songs.artist_id")
        .order(:remote_song_id)
        .pluck(:remote_song_id, "songs.name", "albums.remote_album_id", "artists.remote_artist_id")
    }
  end

  def artist_upsert(id, name, is_various: false)
    { "change_type" => "upsert", "item_type" => "artist", "id" => id, "name" => name, "is_various" => is_various }
  end

  def album_upsert(id, name, artist_id:)
    {
      "change_type" => "upsert", "item_type" => "album", "id" => id, "name" => name,
      "year" => 2020, "genre" => "genre-#{id}", "artist_id" => artist_id, "artist_name" => "artist-#{artist_id}"
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
