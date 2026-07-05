# frozen_string_literal: true

require "test_helper"

# Property-based test for Property 9 of the remote-library-mirror-sync feature.
#
# Design property (remote-library-mirror-sync, Property 9):
#   The mirror stores no audio or artwork bytes (Req 1.4).
#
# `CatalogSync.apply(connection, changes)` materializes a Remote_Library's
# Catalog_Mirror from a set of upsert Catalog_Changes: Mirrored_Songs,
# Mirrored_Albums, and Mirrored_Artists become ordinary Song/Album/Artist rows
# in the connection's `kind: remote` Library. The mirror is metadata only —
# names, durations, track/disc numbers, associations, and hosting-side ids —
# and by Req 1.4 it stores NO audio byte content and NO artwork byte content.
#
# Concretely, in this schema:
#   * A Song stores audio only via its file-backed columns (`file_path`,
#     `file_path_hash`, `md5_hash`) that point at bytes on disk. A Mirrored_Song
#     carries none of these — it streams live through the remote proxy keyed on
#     the stored `remote_song_id` — so all three MUST be null on every mirrored
#     song while `remote_song_id` is present.
#   * An Album/Artist stores artwork via an ActiveStorage `cover_image`
#     attachment (see ImageableConcern#has_cover_image?). A Mirrored_Album /
#     Mirrored_Artist proxies artwork live, so no `cover_image` MUST be attached
#     on any mirrored album or artist.
#
# This test generates randomized catalogs (artists, albums, songs with varied
# metadata and associations), materializes each as a Catalog_Mirror via
# CatalogSync.apply, then asserts the metadata-only invariant holds for every
# materialized row.
class MetadataOnlyInvariantPropertyTest < ActiveSupport::TestCase
  setup do
    @user = users(:visitor1)
    @next_remote_library_id = 0
  end

  # Feature: remote-library-mirror-sync, Property 9: The mirror stores no audio or artwork bytes
  test "materialized mirrors store no audio bytes on songs and no artwork bytes on albums or artists" do
    check_property(iterations: 100) do
      # Describe one catalog to materialize: a pool of artists, albums (each
      # referencing an artist), and songs (each referencing an album + artist),
      # with randomized metadata across the input space. At least one song
      # guarantees the mirror — and thus the invariant — is non-vacuously tested.
      n_artists = range(1, 3)
      n_albums = range(1, 3)
      n_songs = range(1, 5)

      # Names are made distinct per item (index-suffixed) so the generated
      # catalog stays within the valid input space: a real Hosting_Server
      # catalog enforces the same unique indexes on (library, artist name) and
      # (library, artist, album name), so the Changes_Since_API never serves two
      # artists or two co-artist albums that share a name. The metadata-only
      # invariant under test is orthogonal to name collisions.
      artists = Array.new(n_artists) do |i|
        { name: "#{sized(range(1, 12)) { string(:alpha) }}-artist-#{i}", various: boolean }
      end

      albums = Array.new(n_albums) do |i|
        {
          name: "#{sized(range(1, 12)) { string(:alpha) }}-album-#{i}",
          year: range(1900, 2100),
          genre: sized(range(0, 8)) { string(:alpha) },
          artist_index: range(0, n_artists - 1)
        }
      end

      songs = Array.new(n_songs) do
        {
          name: sized(range(0, 24)) { string(:alpha) },
          duration: range(0, 6000).to_f,
          tracknum: range(1, 40),
          discnum: range(1, 5),
          album_index: range(0, n_albums - 1),
          artist_index: range(0, n_artists - 1)
        }
      end

      [ { artists: artists, albums: albums, songs: songs } ]
    end.check do |(catalog)|
      connection = create_active_connection
      library = connection.library

      CatalogSync.apply(connection, build_changes(catalog))
      library.reload

      songs = library.songs.to_a
      albums = library.albums.to_a
      artists = library.artists.to_a

      # Non-vacuity: the catalog always has at least one song, so the mirror is
      # actually materialized before we assert the invariant over it.
      assert_operator songs.size, :>=, 1,
        "expected the materialized mirror to contain at least one Mirrored_Song"

      songs.each do |song|
        # A Mirrored_Song is keyed on its hosting-side id and stores no file.
        assert song.remote_song_id.present?,
          "expected every Mirrored_Song to carry a Remote_Song_Id"
        assert_nil song.file_path,
          "Mirrored_Song stored audio bytes via file_path: #{song.file_path.inspect}"
        assert_nil song.file_path_hash,
          "Mirrored_Song stored audio bytes via file_path_hash: #{song.file_path_hash.inspect}"
        assert_nil song.md5_hash,
          "Mirrored_Song stored audio bytes via md5_hash: #{song.md5_hash.inspect}"
      end

      albums.each do |album|
        assert_not album.has_cover_image?,
          "Mirrored_Album stored artwork bytes: cover_image is attached on album #{album.id}"
      end

      artists.each do |artist|
        assert_not artist.has_cover_image?,
          "Mirrored_Artist stored artwork bytes: cover_image is attached on artist #{artist.id}"
      end
    end
  end

  private

  # A Remote_Library reached through an active Library_Connection — the target
  # of a Catalog_Mirror. A fresh connection/library per iteration keeps each
  # mirror's hosting-side ids independent.
  def create_active_connection
    connection = LibraryConnection.create!(
      user: @user,
      server_base_url: "https://remote.example.com",
      remote_library_id: next_remote_library_id,
      grant_token: "remote-bearer-token",
      status: :active
    )

    Library.create!(
      name: "Mirror Library #{SecureRandom.hex(6)}",
      kind: :remote,
      owner: @user,
      library_connection: connection
    )

    connection
  end

  # Translate a generated catalog into the ordered upsert Catalog_Changes array
  # `CatalogSync.apply` consumes (string-keyed, mirroring the changes-since
  # response). Hosting-side ids are assigned per-index within this connection.
  def build_changes(catalog)
    changes = []

    catalog[:artists].each_with_index do |artist, i|
      changes << {
        "change_type" => "upsert", "item_type" => "artist", "id" => i + 1,
        "name" => artist[:name], "is_various" => artist[:various]
      }
    end

    catalog[:albums].each_with_index do |album, i|
      artist_remote_id = album[:artist_index] + 1
      changes << {
        "change_type" => "upsert", "item_type" => "album", "id" => i + 1,
        "name" => album[:name], "year" => album[:year], "genre" => album[:genre],
        "artist_id" => artist_remote_id,
        "artist_name" => catalog[:artists][album[:artist_index]][:name]
      }
    end

    catalog[:songs].each_with_index do |song, i|
      album_remote_id = song[:album_index] + 1
      artist_remote_id = song[:artist_index] + 1
      changes << {
        "change_type" => "upsert", "item_type" => "song", "id" => i + 1,
        "name" => song[:name], "duration" => song[:duration],
        "tracknum" => song[:tracknum], "discnum" => song[:discnum],
        "album_id" => album_remote_id,
        "album_name" => catalog[:albums][song[:album_index]][:name],
        "artist_id" => artist_remote_id,
        "artist_name" => catalog[:artists][song[:artist_index]][:name]
      }
    end

    changes
  end

  def next_remote_library_id
    @next_remote_library_id += 1
  end
end
