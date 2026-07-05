# frozen_string_literal: true

require "test_helper"

# Unit-level coverage for task 5.6: the `in_library` scope that backs
# browse/search/list scoping. The controller-level behavior is exercised in
# test/controllers/library_scoping_test.rb; these tests pin the scope itself so
# the "zero-library empty results" guarantee (Req 3.7) holds independently of
# any controller wiring, and confirm results are restricted to a single Library
# (Req 3.2).
class LibraryScopedConcernTest < ActiveSupport::TestCase
  setup do
    @active_library = libraries(:default_library)
    @other_library = libraries(:secondary_library)

    # Content that lives in a Library the user is NOT browsing. It must be
    # excluded from any single-library scope and never leak into results.
    @other_artist = Artist.create!(name: "edge_other_artist", library: @other_library)
    @other_album = Album.create!(name: "edge_other_album", artist: @other_artist, library: @other_library)
    @other_song = Song.create!(
      name: "edge_other_song",
      file_path: "/tmp/edge_other_song.mp3",
      file_path_hash: "edge_other_song_path_hash",
      md5_hash: "edge_other_song_md5_hash",
      artist: @other_artist,
      album: @other_album,
      library: @other_library
    )
  end

  # Req 3.7: a User with access to zero Libraries has no Active_Library, which is
  # represented as a nil library. Every scoped query must then yield nothing.
  test "in_library returns an empty relation for Song when the library is nil" do
    assert_empty Song.in_library(nil)
  end

  test "in_library returns an empty relation for Album when the library is nil" do
    assert_empty Album.in_library(nil)
  end

  test "in_library returns an empty relation for Artist when the library is nil" do
    assert_empty Artist.in_library(nil)
  end

  # Req 3.2: browsing is restricted to the Active_Library's content and excludes
  # every other Library's content.
  test "in_library restricts Songs to the given library and excludes others" do
    result = Song.in_library(@active_library)

    assert_includes result, songs(:mp3_sample)
    assert_not_includes result, @other_song
  end

  test "in_library restricts Albums to the given library and excludes others" do
    result = Album.in_library(@active_library)

    assert_includes result, albums(:album1)
    assert_not_includes result, @other_album
  end

  test "in_library restricts Artists to the given library and excludes others" do
    result = Artist.in_library(@active_library)

    assert_includes result, artists(:artist1)
    assert_not_includes result, @other_artist
  end
end
