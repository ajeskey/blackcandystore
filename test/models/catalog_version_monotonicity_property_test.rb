# frozen_string_literal: true

require "test_helper"

# Property-based test for Property 1 of the remote-library-mirror-sync feature.
#
# Design property (remote-library-mirror-sync, Property 1):
#   Catalog_Version is monotonically non-decreasing and strictly increases on
#   change (Req 3.1).
#
# The hosting-side `CatalogVersioning` module is the single origin of every
# catalog-version bump: `record_upsert(item)` records a creation or a metadata
# update, and `record_deletion(type:, remote_id:, library:)` records a removal.
# Each call bumps the owning Local_Library's `catalog_version` and appends one
# `CatalogChange` row stamped with the new version.
#
# This test drives `CatalogVersioning` directly (independent of the `Media`
# scan wiring). It materializes a Local_Library with a small pool of live
# Song/Album/Artist rows, then generates a random sequence of catalog changes —
# additions (upsert of a freshly created row), metadata updates (upsert of an
# existing pooled row), and deletions (`record_deletion` for a hosting-side id)
# — and applies them one at a time. After each change it asserts:
#
#   (Req 3.1) the version never decreases across the sequence
#             (`new_version >= previous_version`), and
#   (Req 3.1) the version strictly increases on every change
#             (`new_version > previous_version`).
#
# Because every recorded change must move the version forward, "monotonically
# non-decreasing" and "strictly increases on change" are checked together at
# each step over an arbitrary interleaving of the three change kinds.
class CatalogVersionMonotonicityPropertyTest < ActiveSupport::TestCase
  # A real, readable directory so `local` libraries pass media-path validation.
  MEDIA_PATH = Rails.root.join("test", "fixtures", "files").to_s

  # Ids used for deletion changes: far outside the live autoincrement range so a
  # deletion never collides with a materialized row.
  DELETED_ID_BASE = 10_000_000

  CHANGE_KINDS = %i[addition metadata_update deletion].freeze

  setup do
    @owner = users(:admin)
    @seq = 0
  end

  # Feature: remote-library-mirror-sync, Property 1: Catalog_Version is monotonically non-decreasing and strictly increases on change
  test "catalog_version never decreases and strictly increases on every catalog change" do
    check_property(iterations: 100) do
      # Seed pool: at least one song/album/artist so metadata-update changes
      # always have an existing row to upsert.
      pool_spec = { artists: range(1, 3), albums: range(1, 3), songs: range(1, 4) }

      # A random sequence of catalog changes over the three change kinds.
      change_kinds = Array.new(range(1, 15)) { CHANGE_KINDS[range(0, CHANGE_KINDS.size - 1)] }

      [ pool_spec, change_kinds ]
    end.check do |(pool_spec, change_kinds)|
      # Isolate each iteration so the version starts from a known baseline.
      CatalogChange.delete_all
      Song.delete_all
      Album.delete_all
      Artist.delete_all
      Library.delete_all

      library, items = build_pool(pool_spec)

      # The pool is built with plain create! calls, which do NOT go through
      # CatalogVersioning, so the version starts at its default of 0.
      previous_version = library.reload.catalog_version
      deleted_seq = 0

      change_kinds.each do |kind|
        case kind
        when :addition
          # A newly created content item recorded as an upsert.
          CatalogVersioning.record_upsert(create_song(library, items))
        when :metadata_update
          # An existing pooled item whose metadata changed, recorded as upsert.
          item = items.sample
          item[:record].update_column(:name, "Renamed-#{next_seq}")
          CatalogVersioning.record_upsert(item[:record])
        when :deletion
          deleted_seq += 1
          CatalogVersioning.record_deletion(
            type: "song",
            remote_id: DELETED_ID_BASE + deleted_seq,
            library: library
          )
        end

        new_version = library.reload.catalog_version

        assert_operator new_version, :>=, previous_version,
          "catalog_version must never decrease (was #{previous_version}, now #{new_version} after #{kind})"
        assert_operator new_version, :>, previous_version,
          "catalog_version must strictly increase on every change (stayed #{new_version} after #{kind})"

        previous_version = new_version
      end
    end
  end

  private

  def next_seq
    @seq += 1
  end

  # Materialize a fresh Local_Library with a pool of live Song/Album/Artist
  # rows. Returns the library and a flat list of item descriptors, each holding
  # the live record so metadata-update changes can upsert an existing row.
  def build_pool(pool_spec)
    library = Library.create!(
      name: "P1-Lib-#{next_seq}",
      kind: "local",
      media_path: MEDIA_PATH,
      owner: @owner
    )

    artists = Array.new(pool_spec[:artists]) do
      Artist.create!(name: "Artist-#{next_seq}", library: library)
    end

    albums = Array.new(pool_spec[:albums]) do |i|
      Album.create!(name: "Album-#{next_seq}", artist: artists[i % artists.size], library: library)
    end

    songs = Array.new(pool_spec[:songs]) do |i|
      album = albums[i % albums.size]
      build_song(library, album)
    end

    items =
      songs.map { |s| { type: "song", record: s } } +
      albums.map { |a| { type: "album", record: a } } +
      artists.map { |a| { type: "artist", record: a } }

    [ library, items ]
  end

  # Create a brand-new song attached to an existing (or freshly created) album,
  # used to model an "addition" catalog change.
  def create_song(library, items)
    album = items.map { |i| i[:record] }.grep(Album).sample
    album ||= Album.create!(name: "Album-#{next_seq}", artist: Artist.create!(name: "Artist-#{next_seq}", library: library), library: library)
    song = build_song(library, album)
    items << { type: "song", record: song }
    song
  end

  def build_song(library, album)
    n = next_seq
    Song.create!(
      name: "Song-#{n}",
      duration: 100.0 + n,
      tracknum: (n % 12) + 1,
      discnum: 1,
      file_path: "/tmp/song-#{n}.mp3",
      file_path_hash: "fph-#{n}",
      md5_hash: "md5-#{n}",
      library: library,
      album: album,
      artist: album.artist
    )
  end
end
