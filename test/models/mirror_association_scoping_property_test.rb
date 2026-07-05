# frozen_string_literal: true

require "test_helper"

# Property-based test for Property 8 of the remote-library-mirror-sync feature.
#
# Design property (remote-library-mirror-sync, Property 8):
#   When CatalogSync materializes a Catalog_Mirror for a Library_Connection, each
#   Mirrored_Song SHALL link the Mirrored_Album and Mirrored_Artist that carry
#   the matching hosting-side identifiers, every mirrored item SHALL be scoped to
#   exactly one Remote_Library, and two distinct Library_Connections that mirror
#   content sharing the same hosting-side identifier value SHALL keep their
#   mirrors separate so neither connection's items are attributed to the other
#   (Req 1.2, 1.3, 1.5, 2.1, 2.2, 2.3, 2.4).
#
# A remote Library has exactly one Library_Connection, so scoping by `library_id`
# is scoping by connection. This test generates ONE catalog described purely by
# hosting-side ids, then applies the *identical* change set — the same hosting
# song/album/artist ids — to two or three independent remote Libraries. Because
# the ids are shared, any leak of identity between connections would surface as
# a shared row or a mis-wired association. For every connection it asserts:
#
#   (a) each Mirrored_Song's album carries the song's hosting-side album id and
#       its artist carries the song's hosting-side artist id, both within the
#       same remote Library (association preservation, Req 1.2, 1.3, 2.1);
#   (b) every mirrored row lives in exactly one of the generated Remote_Libraries
#       (per-connection scoping, Req 1.5, 2.2, 2.3); and
#   (c) a hosting-side id shared across connections resolves to a DISTINCT row in
#       each Library, never cross-attributed (Req 2.4).
class MirrorAssociationScopingPropertyTest < ActiveSupport::TestCase
  setup do
    @user = users(:visitor1)
    @remote_library_seq = 0
  end

  # Feature: remote-library-mirror-sync, Property 8: Mirrored items preserve associations and stay scoped per connection
  test "mirrored songs link the album/artist carrying the matching hosting id, every item is scoped to one library, and connections sharing a hosting id never cross-attribute" do
    check_property(iterations: 100) do
      # Generate a single catalog as pure hosting-side id data. `artist_ids`,
      # `albums` (id + hosting artist id), and `songs` (id + hosting album/artist
      # ids) describe the host's catalog; the SAME ids are mirrored by every
      # connection so cross-attribution would be observable. All DB work happens
      # in the assertion block.
      artist_ids = (1..range(1, 4)).to_a

      albums = Array.new(range(1, 5)) do |i|
        { id: i + 1, artist_id: choose(*artist_ids) }
      end

      songs = Array.new(range(1, 8)) do |i|
        album = albums[range(0, albums.length - 1)]
        # Songs share their album's artist, as the host scanner produces.
        { id: i + 1, album_id: album[:id], artist_id: album[:artist_id] }
      end

      connection_count = range(2, 3)

      [ artist_ids, albums, songs, connection_count ]
    end.check do |(artist_ids, albums, songs, connection_count)|
      # Isolate each iteration from fixtures and prior iterations so the global
      # scoping assertions are computed only over this iteration's data.
      Song.delete_all
      Album.delete_all
      Artist.delete_all
      Library.delete_all
      LibraryConnection.delete_all

      changes = build_change_set(artist_ids, albums, songs)

      expected_song_ids = songs.map { |s| s[:id] }.uniq
      expected_album_ids = albums.map { |a| a[:id] }.uniq
      expected_artist_ids = artist_ids.uniq
      # Hosting-side album/artist id each song must resolve to, by hosting song id.
      album_for_song = songs.to_h { |s| [ s[:id], s[:album_id] ] }
      artist_for_song = songs.to_h { |s| [ s[:id], s[:artist_id] ] }

      libraries = Array.new(connection_count) { materialize_mirror(changes) }
      library_ids = libraries.map(&:id)

      libraries.each do |library|
        # (b) Per-connection scoping: the mirror holds exactly this catalog's
        # items, all owned by this one Remote_Library (Req 1.5, 2.3).
        mirror_songs = library.songs.to_a
        assert_equal expected_song_ids.sort, mirror_songs.map(&:remote_song_id).sort,
          "mirror #{library.id} songs did not match the host catalog by hosting-side id"
        assert_equal expected_album_ids.sort, library.albums.pluck(:remote_album_id).sort,
          "mirror #{library.id} albums did not match the host catalog by hosting-side id"
        assert_equal expected_artist_ids.sort, library.artists.pluck(:remote_artist_id).sort,
          "mirror #{library.id} artists did not match the host catalog by hosting-side id"

        mirror_songs.each do |song|
          # (a) Association preservation: album/artist carry the matching hosting
          # id AND live in the same Remote_Library (Req 1.2, 1.3, 2.1).
          assert_equal album_for_song[song.remote_song_id], song.album.remote_album_id,
            "song #{song.remote_song_id} in mirror #{library.id} linked the wrong hosting album"
          assert_equal artist_for_song[song.remote_song_id], song.artist.remote_artist_id,
            "song #{song.remote_song_id} in mirror #{library.id} linked the wrong hosting artist"
          assert_equal library.id, song.album.library_id,
            "song #{song.remote_song_id} in mirror #{library.id} linked an album from another library"
          assert_equal library.id, song.artist.library_id,
            "song #{song.remote_song_id} in mirror #{library.id} linked an artist from another library"
          assert_equal library.id, song.library_id
        end
      end

      # (c) Two connections sharing a hosting-side id never cross-attribute: each
      # shared id maps to a DISTINCT row per Library, and each row is scoped to
      # exactly one of the generated Remote_Libraries (Req 2.2, 2.4).
      assert_shared_ids_stay_separate(
        model: Song, column: :remote_song_id, ids: expected_song_ids,
        library_ids: library_ids, connection_count: connection_count
      )
      assert_shared_ids_stay_separate(
        model: Album, column: :remote_album_id, ids: expected_album_ids,
        library_ids: library_ids, connection_count: connection_count
      )
      assert_shared_ids_stay_separate(
        model: Artist, column: :remote_artist_id, ids: expected_artist_ids,
        library_ids: library_ids, connection_count: connection_count
      )
    end
  end

  private

  # Turn the generated id-only catalog into the ordered `changes` array a
  # changes-since response would carry (string-keyed, as parsed off the wire).
  def build_change_set(artist_ids, albums, songs)
    changes = []

    artist_ids.each do |aid|
      changes << {
        "change_type" => "upsert", "item_type" => "artist", "id" => aid,
        "name" => "Artist #{aid}", "is_various" => false
      }
    end

    albums.each do |album|
      changes << {
        "change_type" => "upsert", "item_type" => "album", "id" => album[:id],
        "name" => "Album #{album[:id]}", "year" => 2000, "genre" => "Rock",
        "artist_id" => album[:artist_id], "artist_name" => "Artist #{album[:artist_id]}"
      }
    end

    songs.each do |song|
      changes << {
        "change_type" => "upsert", "item_type" => "song", "id" => song[:id],
        "name" => "Song #{song[:id]}", "duration" => 123.0, "tracknum" => 1, "discnum" => 1,
        "album_id" => song[:album_id], "album_name" => "Album #{song[:album_id]}",
        "artist_id" => song[:artist_id], "artist_name" => "Artist #{song[:artist_id]}"
      }
    end

    changes
  end

  # Create a fresh active Library_Connection + remote Library and apply the
  # shared change set to it, returning the reloaded mirror Library.
  def materialize_mirror(changes)
    @remote_library_seq += 1
    connection = LibraryConnection.create!(
      user: @user,
      server_base_url: "https://host.example.com",
      remote_library_id: @remote_library_seq,
      grant_token: "grant-token-#{@remote_library_seq}",
      status: :active
    )
    library = Library.create!(
      name: "Remote Mirror #{@remote_library_seq}",
      kind: :remote,
      owner: @user,
      library_connection: connection
    )

    CatalogSync.apply(connection, changes)
    library.reload
  end

  # Assert every hosting-side id maps to `connection_count` distinct rows — one
  # per Library — with distinct primary keys and distinct owning libraries, so
  # no connection's mirrored item is attributed to another (Req 2.2, 2.4).
  def assert_shared_ids_stay_separate(model:, column:, ids:, library_ids:, connection_count:)
    ids.each do |hosting_id|
      rows = model.where(column => hosting_id, library_id: library_ids).to_a

      assert_equal connection_count, rows.length,
        "hosting #{model.name.downcase} id #{hosting_id} should map to one distinct row per connection"
      assert_equal connection_count, rows.map(&:id).uniq.length,
        "hosting #{model.name.downcase} id #{hosting_id} mapped to a shared row across connections"
      assert_equal library_ids.sort, rows.map(&:library_id).sort,
        "hosting #{model.name.downcase} id #{hosting_id} was not scoped to exactly one row per library"
    end
  end
end
