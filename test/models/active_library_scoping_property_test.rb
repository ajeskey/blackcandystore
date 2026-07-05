# frozen_string_literal: true

require "test_helper"

# Property-based test for Property 5 of the multi-server-library-sharing
# feature.
#
# Design property (multi-server-library-sharing, Property 5):
#   For any User with an Active_Library over any multi-library dataset, the
#   songs, albums, and artists returned by browsing, searching, and listing
#   SHALL be a subset of the Active_Library's content and SHALL be disjoint
#   from the content of every other Library (Req 3.2). While a User has access
#   to zero Libraries, browsing, searching, and listing SHALL return empty
#   results (Req 3.7).
#
# Browsing/searching/listing are all built on the shared `in_library` scope
# (see LibraryScopedConcern), which is what the LibraryScoping controller
# concern wraps via `scoped_to_active_library(relation) =
# relation.in_library(Current.user&.active_library)`. This test exercises that
# scope directly on the three content models across randomized multi-library
# datasets, varying which library is the User's Active_Library (and including
# the zero-accessible-libraries case where there is no Active_Library).
#
# For each generated dataset it asserts, for Song, Album, and Artist:
#   (subset)     every result belongs to the active library, and
#   (disjoint)   no result belongs to any other library, and
#   (empty)      when the User has no Active_Library, results are empty.
class ActiveLibraryScopingPropertyTest < ActiveSupport::TestCase
  setup do
    @seq = 0
  end

  # Feature: multi-server-library-sharing, Property 5: Browsing results are scoped to the active library
  test "browse/search/list results are a subset of the active library and disjoint from every other library" do
    check_property(iterations: 100) do
      # Describe a multi-library dataset: several libraries, each with its own
      # count of songs (each song gets its own album and artist so the content
      # sets are fully distinct per library). `active_selector` chooses the
      # User's Active_Library: an index into the libraries, or -1 to model a
      # User with access to zero Libraries (no Active_Library at all).
      lib_count = range(2, 4)
      song_counts = Array.new(lib_count) { range(1, 4) }
      active_selector = range(-1, lib_count - 1)

      [ song_counts, active_selector ]
    end.check do |(song_counts, active_selector)|
      # Isolate each iteration so assertions only observe this dataset.
      Song.delete_all
      Album.delete_all
      Artist.delete_all
      Library.where.not(id: [ libraries(:default_library).id, libraries(:secondary_library).id ]).delete_all
      # Detach fixture content from the two persistent fixture libraries so the
      # global content set is exactly what this iteration builds.
      user = build_user

      libraries, content_by_library = build_dataset(song_counts)

      active_library =
        if active_selector.negative?
          nil
        else
          libraries[active_selector]
        end

      user.update_column(:active_library_id, active_library&.id)

      # The Active_Library resolved for the User is what browsing scopes to.
      resolved = user.active_library
      # When no library is active (zero accessible libraries), every scoped
      # query must be empty (Req 3.7).
      if resolved.nil?
        assert_empty Song.in_library(resolved).to_a, "expected no songs when there is no active library"
        assert_empty Album.in_library(resolved).to_a, "expected no albums when there is no active library"
        assert_empty Artist.in_library(resolved).to_a, "expected no artists when there is no active library"
        next
      end

      active_content = content_by_library.fetch(resolved.id)
      other_content = content_by_library.reject { |lib_id, _| lib_id == resolved.id }.values

      assert_scoped(Song, resolved, active_content[:song_ids], other_content.flat_map { |c| c[:song_ids] })
      assert_scoped(Album, resolved, active_content[:album_ids], other_content.flat_map { |c| c[:album_ids] })
      assert_scoped(Artist, resolved, active_content[:artist_ids], other_content.flat_map { |c| c[:artist_ids] })
    end
  end

  private

  # Assert the subset + disjointness invariant for one content model.
  def assert_scoped(model, active_library, active_ids, other_ids)
    result_ids = model.in_library(active_library).pluck(:id).to_set
    active_set = active_ids.to_set
    other_set = other_ids.to_set

    # (subset) every returned row belongs to the active library's content.
    assert result_ids.subset?(active_set),
      "#{model.name} results #{result_ids.to_a} are not a subset of active library content #{active_set.to_a}"

    # Completeness: the scope returns exactly the active library's content.
    assert_equal active_set, result_ids,
      "#{model.name} results #{result_ids.to_a} do not equal active library content #{active_set.to_a}"

    # (disjoint) no returned row belongs to any other library's content.
    assert (result_ids & other_set).empty?,
      "#{model.name} results #{result_ids.to_a} overlap other libraries' content #{other_set.to_a}"
  end

  def next_seq
    @seq += 1
  end

  # A fresh, persisted User whose Active_Library we set explicitly. Owning no
  # libraries keeps `accessible_libraries` empty so the -1 selector genuinely
  # models a zero-access User.
  def build_user
    User.create!(email: "prop5-#{SecureRandom.uuid}@example.com", password: "foobar123")
  end

  # Materialize `song_counts` into distinct Library/Artist/Album/Song rows.
  # Returns the created libraries and a map of library_id => { song_ids,
  # album_ids, artist_ids }. `remote` libraries skip media-path validation while
  # still exercising the same content association and scoping behavior.
  def build_dataset(song_counts)
    content_by_library = {}

    libraries = song_counts.map do |song_count|
      library = Library.create!(name: "Prop5-Lib-#{next_seq}", kind: "remote")

      song_ids = []
      album_ids = []
      artist_ids = []

      song_count.times do
        n = next_seq
        artist = Artist.create!(name: "Artist-#{n}", library: library)
        album = Album.create!(name: "Album-#{n}", artist: artist, library: library)
        song = Song.create!(
          name: "Song-#{n}",
          file_path: "/tmp/song-#{n}.mp3",
          file_path_hash: "fph-#{n}",
          md5_hash: "md5-#{n}",
          library: library,
          album: album,
          artist: artist
        )

        song_ids << song.id
        album_ids << album.id
        artist_ids << artist.id
      end

      content_by_library[library.id] = { song_ids:, album_ids:, artist_ids: }
      library
    end

    [ libraries, content_by_library ]
  end
end
