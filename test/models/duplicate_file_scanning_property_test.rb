# frozen_string_literal: true

require "test_helper"

# Property-based test for scanning the same media file under two libraries.
#
# Design property (multi-server-library-sharing, Property 3):
#   For any media file present under the media paths of two distinct
#   Local_Libraries, scanning SHALL produce two separate Songs, one associated
#   with each Library.
#
# `Media.sync(type, file_paths, library_id:)` scopes its artist/album/song
# `create_or_find_by!` lookups to the given `library_id` (the
# `(library_id, md5_hash)` key from the relaxed schema). So the exact same file
# — identical `md5_hash` and metadata — scanned once per library must yield two
# distinct Song rows, one per library, rather than colliding into a single row.
#
# The test drives `Media.sync` with a real fixture file whose metadata (and the
# derived `md5_hash`) is stubbed to a generated value each iteration, exercising
# a wide range of files without needing physical duplicates on disk.
class DuplicateFileScanningPropertyTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    clear_media_data
    @library_one = libraries(:default_library)
    @library_two = libraries(:secondary_library)
    @base_file = fixtures_file_path("artist1_album2.mp3")
  end

  # Feature: multi-server-library-sharing, Property 3: Same file under two libraries yields two songs
  test "the same media file scanned under two libraries yields two songs, one per library" do
    check_property(iterations: 100) do
      # Vary the derived md5_hash and the core metadata so the property is
      # exercised across many distinct "files". `image`/`albumartist_name` are
      # pinned so each iteration stays fast and takes the plain-artist branch.
      {
        md5_hash: sized(range(8, 24)) { string(:alnum) },
        name: sized(range(1, 20)) { string(:alpha) },
        artist_name: sized(range(1, 15)) { string(:alpha) },
        album_name: sized(range(1, 15)) { string(:alpha) },
        albumartist_name: nil,
        image: nil
      }
    end.check do |attributes|
      # Start each iteration from a clean slate so counts are unambiguous.
      clear_media_data

      stub_file_metadata(@base_file, attributes) do
        Media.sync(:added, [ @base_file ], library_id: @library_one.id)
        Media.sync(:added, [ @base_file ], library_id: @library_two.id)
      end

      md5_hash = attributes[:md5_hash]
      songs = Song.where(md5_hash: md5_hash)

      assert_equal 2, songs.count,
        "expected two songs for md5_hash=#{md5_hash.inspect}, got #{songs.count}"

      assert_equal 1, songs.where(library_id: @library_one.id).count,
        "expected exactly one song in library_one for md5_hash=#{md5_hash.inspect}"

      assert_equal 1, songs.where(library_id: @library_two.id).count,
        "expected exactly one song in library_two for md5_hash=#{md5_hash.inspect}"

      assert_equal [ @library_one.id, @library_two.id ].sort,
        songs.pluck(:library_id).sort,
        "expected one song per distinct library for md5_hash=#{md5_hash.inspect}"
    end
  end
end
