# frozen_string_literal: true

require "test_helper"

# Property-based test for Property 2 of the multi-server-library-sharing
# feature. It scans real media fixtures into several libraries and asserts the
# fundamental scoping invariant: after scanning, every Song is associated with
# exactly one Library.
class SingleLibraryAssociationPropertyTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  # A small pool of parseable audio fixtures. Keeping the pool small keeps the
  # 100+ generated iterations fast while still exercising several distinct
  # media files across libraries.
  FILE_POOL = %w[
    artist1_album2.mp3
    artist1_album1.flac
    artist2_album3.ogg
  ].freeze

  # Feature: multi-server-library-sharing, Property 2: Every song belongs to exactly one library
  test "every scanned song is associated with exactly one library" do
    check_property(iterations: 100) do
      # Generate a scanned-content set spread across multiple libraries: pick a
      # number of libraries and, for each, a non-empty subset of the file pool
      # to scan into it.
      library_count = choose(2, 3, 4)

      Array.new(library_count) do
        chosen = FILE_POOL.select { boolean }
        chosen.empty? ? FILE_POOL.dup : chosen
      end
    end.check do |library_file_sets|
      # Start each iteration from a clean content slate so the assertions only
      # observe the songs produced by this iteration's scan.
      clear_media_data

      libraries = library_file_sets.map do
        Library.create!(name: "prop2-library-#{SecureRandom.uuid}", kind: "remote")
      end
      library_ids = libraries.map(&:id)

      libraries.each_with_index do |library, index|
        file_paths = library_file_sets[index].map { |name| file_fixture(name).to_s }
        Media.sync(:added, file_paths, library_id: library.id)
      end

      songs = Song.all.to_a
      assert songs.any?, "expected the scan to produce at least one song"

      songs.each do |song|
        # Non-null association referencing one of the libraries we scanned into.
        refute_nil song.library_id, "song #{song.id} is not associated with any library"
        assert_includes library_ids, song.library_id,
          "song #{song.id} references library #{song.library_id} outside the scanned set"

        # Exactly one Library record backs the association.
        assert_equal 1, Library.where(id: song.library_id).count,
          "song #{song.id} does not reference exactly one library"
        assert_not_nil song.library, "song #{song.id} cannot resolve its library association"
      end

      # The per-library song counts partition the full set: no song is counted
      # under more than one library, confirming single (not shared) membership.
      total_across_libraries = library_ids.sum { |id| Song.where(library_id: id).count }
      assert_equal songs.size, total_across_libraries,
        "songs are not partitioned across libraries (a song belongs to more than one library)"
    end
  end
end
