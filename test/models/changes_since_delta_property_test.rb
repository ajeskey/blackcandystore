# frozen_string_literal: true

require "test_helper"

# Property-based test for Property 2 of the remote-library-mirror-sync feature.
#
# Design property (remote-library-mirror-sync, Property 2):
#   Changes-since returns exactly the post-cursor changes in order, and is
#   empty at or beyond the current version (Req 3.2, 3.4, 3.5, 3.6, 3.7).
#
# `CatalogChange.changes_since(library, cursor, page)` serves the hosting-side
# change log to a redeeming server: the ordered deltas after a Sync_Cursor plus
# the Catalog_Version to adopt. This test generates randomized change logs over
# a freshly materialized Local_Library — a pool of live Song/Album/Artist rows
# whose ids the log's upserts reference, plus deletions referencing ids whose
# rows are gone — assigns each change a strictly increasing version (so the log
# has a well-defined retention floor and current version), and probes it with
# cursors spanning below the floor, inside the retained window, and at or beyond
# the current version.
#
# For each generated (log, cursor) it asserts the exhaustive contract:
#   (Req 3.6) cursor >= current version  -> empty change set, current version,
#             not full-sync-required;
#   (Req 3.7) cursor below the retained floor (floor > cursor + 1) ->
#             full-sync-required, no partial set, current version;
#   (Req 3.2) otherwise the returned changes are EXACTLY the post-cursor log
#             rows in non-decreasing version order, and
#   (Req 3.4) each upsert carries its id/type and a hydrated live record with
#             the item's metadata (name) and associations (album/artist), and
#   (Req 3.5) each deletion carries its id/type with no hydrated record.
#
# The exact element-wise comparison against the version-sorted expectation
# validates both the content and the ordering simultaneously: the returned
# sequence equals a sequence built in ascending version order, so order is
# proven by construction. Generated logs stay within one pagy page (limit 30)
# so the first page holds every post-cursor change.
class ChangesSinceDeltaPropertyTest < ActiveSupport::TestCase
  # A real, readable directory so `local` libraries pass media-path validation.
  MEDIA_PATH = Rails.root.join("test", "fixtures", "files").to_s

  # Ids used for deletion changes: far outside the live autoincrement range so a
  # deletion never collides with a materialized (upsertable) row (Req 3.5).
  DELETED_ID_BASE = 10_000_000

  ITEM_KINDS = %w[song album artist].freeze

  setup do
    @owner = users(:admin)
    @seq = 0
  end

  # Feature: remote-library-mirror-sync, Property 2: Changes-since returns exactly the post-cursor changes in order, and is empty at or beyond the current version
  test "changes_since returns exactly the post-cursor changes in version order and is empty at or beyond the current version" do
    check_property(iterations: 100) do
      # Pool spec: how many artists/albums/songs to materialize as upsertable
      # live rows. At least one song guarantees a non-empty upsert pool.
      pool_spec = { artists: range(1, 3), albums: range(1, 3), songs: range(1, 4) }

      # Change-log spec: strictly increasing versions starting at a floor >= 1
      # (so cursors below the floor are reachable), each change either an upsert
      # of a pooled item (by index) or a deletion of a gone item (by kind).
      n_changes = range(1, 12)
      version = range(1, 8) # the retained floor
      changes_spec = Array.new(n_changes) do
        entry =
          if range(0, 3) < 3
            { kind: :upsert, index: range(0, 60) }
          else
            { kind: :deletion, item_kind: ITEM_KINDS[range(0, 2)] }
          end
        entry[:version] = version
        version += range(1, 3) # keep versions strictly increasing
        entry
      end

      catalog_version = changes_spec.last[:version]
      # Cursors from 0 (below any floor > 1) through beyond the current version
      # so every branch — full-sync, incremental, and empty — is exercised.
      cursor = range(0, catalog_version + 2)

      [ pool_spec, changes_spec, catalog_version, cursor ]
    end.check do |(pool_spec, changes_spec, catalog_version, cursor)|
      # Isolate each iteration so the change-log floor and current version are
      # exactly what this iteration builds.
      CatalogChange.delete_all
      Song.delete_all
      Album.delete_all
      Artist.delete_all
      Library.delete_all

      library, items = build_pool(pool_spec)
      log = build_log(library, changes_spec, items)
      library.update_column(:catalog_version, catalog_version)

      result = CatalogChange.changes_since(library, cursor, 1)
      floor = log.map { |row| row[:version] }.min

      if cursor >= catalog_version
        # Req 3.6: at or beyond the current version there is nothing after the
        # cursor.
        assert_not result.full_sync_required, "expected no full-sync at/beyond current version"
        assert_empty result.changes, "expected an empty change set at/beyond current version"
        assert_equal catalog_version, result.catalog_version
      elsif floor > cursor + 1
        # Req 3.7: the cursor sits below the retained floor, so the deltas it
        # needs are compacted away and a full sync is required.
        assert result.full_sync_required, "expected full-sync-required below the retained floor"
        assert_empty result.changes, "expected no partial change set when full-sync is required"
        assert_equal catalog_version, result.catalog_version
      else
        # Req 3.2: exactly the post-cursor changes, in non-decreasing version
        # order. Building the expectation in ascending version order and
        # comparing element-wise proves both content and ordering at once.
        assert_not result.full_sync_required, "expected an incremental delta within the retained window"
        assert_equal catalog_version, result.catalog_version

        expected = log.select { |row| row[:version] > cursor }.sort_by { |row| row[:version] }

        assert_equal expected.size, result.changes.size,
          "returned change count does not match the post-cursor rows"

        expected.zip(result.changes).each do |exp, actual|
          assert_equal exp[:change_type], actual.change_type
          assert_equal exp[:item_type], actual.item_type
          assert_equal exp[:item_id], actual.id

          if exp[:change_type] == "deletion"
            # Req 3.5: a deletion is fully described by id + type; no record.
            assert_nil actual.record, "deletion changes carry no hydrated record"
          else
            # Req 3.4: an upsert carries a hydrated live record with metadata
            # and associations.
            assert_not_nil actual.record, "upsert changes carry a hydrated record"
            assert_equal exp[:item_id], actual.record.id
            assert_equal exp[:item][:name], actual.record.name, "upsert preserves the item's metadata"

            case exp[:item_type]
            when "song"
              assert_equal exp[:item][:album_id], actual.record.album_id, "upsert preserves the song's album association"
              assert_equal exp[:item][:artist_id], actual.record.artist_id, "upsert preserves the song's artist association"
            when "album"
              assert_equal exp[:item][:artist_id], actual.record.artist_id, "upsert preserves the album's artist association"
            end
          end
        end

        # Ordering is non-decreasing by version: the returned sequence equals
        # `expected`, which was sorted ascending by version above.
      end
    end
  end

  private

  def next_seq
    @seq += 1
  end

  # Materialize a fresh Local_Library with a pool of live Song/Album/Artist
  # rows. Returns the library and a flat list of item descriptors capturing each
  # item's hosting-side id (its actual DB id), type, name, and associations so
  # upsert changes can reference them and expectations can be computed without
  # re-reading the rows under test.
  def build_pool(pool_spec)
    library = Library.create!(
      name: "P2-Lib-#{next_seq}",
      kind: "local",
      media_path: MEDIA_PATH,
      owner: @owner
    )

    artists = Array.new(pool_spec[:artists]) do
      n = next_seq
      Artist.create!(name: "Artist-#{n}", library: library)
    end

    albums = Array.new(pool_spec[:albums]) do |i|
      n = next_seq
      Album.create!(name: "Album-#{n}", artist: artists[i % artists.size], library: library)
    end

    songs = Array.new(pool_spec[:songs]) do |i|
      n = next_seq
      album = albums[i % albums.size]
      Song.create!(
        name: "Song-#{n}",
        duration: 100.0 + n,
        tracknum: (i % 12) + 1,
        discnum: 1,
        file_path: "/tmp/song-#{n}.mp3",
        file_path_hash: "fph-#{n}",
        md5_hash: "md5-#{n}",
        library: library,
        album: album,
        artist: album.artist
      )
    end

    items =
      songs.map { |s| { type: "song", id: s.id, name: s.name, album_id: s.album_id, artist_id: s.artist_id } } +
      albums.map { |a| { type: "album", id: a.id, name: a.name, artist_id: a.artist_id } } +
      artists.map { |a| { type: "artist", id: a.id, name: a.name } }

    [ library, items ]
  end

  # Persist the generated change-log spec into `catalog_changes` rows. Upserts
  # reference a pooled live item (by index, wrapped into range); deletions
  # reference a gone item id drawn from a disjoint high-id range. Returns the
  # log as descriptors (with the referenced item for upserts) for building the
  # expectation.
  def build_log(library, changes_spec, items)
    deleted_seq = 0

    changes_spec.map do |spec|
      if spec[:kind] == :upsert
        item = items[spec[:index] % items.size]
        row = { version: spec[:version], item_type: item[:type], item_id: item[:id], change_type: "upsert", item: item }
      else
        deleted_seq += 1
        row = { version: spec[:version], item_type: spec[:item_kind], item_id: DELETED_ID_BASE + deleted_seq, change_type: "deletion", item: nil }
      end

      CatalogChange.create!(
        library_id: library.id,
        version: row[:version],
        item_type: row[:item_type],
        item_id: row[:item_id],
        change_type: row[:change_type]
      )

      row
    end
  end
end
