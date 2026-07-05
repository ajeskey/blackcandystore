# frozen_string_literal: true

require "test_helper"

# Property-based test for the library deletion cascade.
#
# Design property (multi-server-library-sharing, Property 4):
#   For any dataset of songs, albums, and artists across libraries, deleting a
#   Local_Library SHALL remove that Library's songs and SHALL remove an Album
#   or Artist if and only if no song remains associated with it afterward
#   (Req 2.4, 2.5).
#
# The cascade is implemented by `Library#before_destroy :destroy_scoped_content`
# which destroys the library's songs and then runs the library-scoped
# `Media.clean_up`. This test builds randomized datasets of artists/albums/songs
# spread across several distinct local libraries (album/artist rows are DISTINCT
# per library, matching the library-scoped uniqueness in the schema), deletes
# one library, and asserts:
#
#   (a) every song of the deleted library is removed,
#   (b) an album/artist row survives if and only if at least one song still
#       references it after the deletion, and
#   (c) every other library's content is preserved.
#
# Datasets are generated so that every album and artist starts with at least one
# song and each song's artist matches its album's artist (as produced by the
# scanner). Under those conditions "no song remains associated with it" is
# exactly equivalent to the row belonging to the deleted library, which lets the
# test assert the iff independently of the cascade's implementation details.
class LibraryDeletionCascadePropertyTest < ActiveSupport::TestCase
  # A real, readable directory so `local` libraries pass media-path validation.
  MEDIA_PATH = Rails.root.join("test", "fixtures", "files").to_s

  setup do
    @owner = users(:admin)
    @seq = 0
  end

  # Feature: multi-server-library-sharing, Property 4: Library deletion cascade preserves exactly the still-referenced albums and artists
  test "deleting a library removes its songs and drops an album/artist iff no song still references it" do
    check_property(iterations: 100) do
      # Generate a shape describing several libraries. Each library is an array
      # of artists; each artist is an array of albums; each album is a count of
      # songs (>= 1) belonging to it. `delete_index` selects the library to
      # delete. Generation is pure data with no DB side effects.
      lib_count = range(2, 4)
      libraries_spec = Array.new(lib_count) do
        artist_count = range(1, 3)
        Array.new(artist_count) do
          album_count = range(1, 3)
          Array.new(album_count) { range(1, 3) }
        end
      end

      [ libraries_spec, range(0, lib_count - 1) ]
    end.check do |(libraries_spec, delete_index)|
      # Isolate each iteration: start from an empty content/library set so the
      # global "survives iff referenced" assertion is not perturbed by fixtures
      # or the previous iteration. delete_all skips callbacks, which is safe
      # because content is cleared first.
      Song.delete_all
      Album.delete_all
      Artist.delete_all
      Library.delete_all

      libraries, songs = build_dataset(libraries_spec)
      deleted_library = libraries[delete_index]

      # Capture the full pre-deletion picture so expectations are computed from
      # the generated dataset, not from the cascade under test.
      album_ids = songs.map { |s| s[:album_id] }.uniq
      artist_ids = songs.map { |s| s[:artist_id] }.uniq
      deleted_song_ids = songs.select { |s| s[:library_id] == deleted_library.id }.map { |s| s[:id] }

      remaining_songs = songs.reject { |s| s[:library_id] == deleted_library.id }
      surviving_album_ids = remaining_songs.map { |s| s[:album_id] }.to_set
      surviving_artist_ids = remaining_songs.map { |s| s[:artist_id] }.to_set

      deleted_library.destroy!

      # (a) every song of the deleted library is gone.
      assert_equal 0, Song.where(id: deleted_song_ids).count,
        "expected all songs of deleted library #{deleted_library.id} to be removed"

      # The deleted library row itself is gone; others remain.
      assert_not Library.exists?(deleted_library.id)

      # (b) an album/artist survives iff at least one song still references it.
      album_ids.each do |album_id|
        expected = surviving_album_ids.include?(album_id)
        assert_equal expected, Album.exists?(album_id),
          "album #{album_id} survival mismatch (referenced_after=#{expected})"
      end

      artist_ids.each do |artist_id|
        expected = surviving_artist_ids.include?(artist_id)
        assert_equal expected, Artist.exists?(artist_id),
          "artist #{artist_id} survival mismatch (referenced_after=#{expected})"
      end

      # (c) every other library's content is preserved intact.
      remaining_songs.each do |s|
        assert Song.exists?(s[:id]), "surviving song #{s[:id]} was unexpectedly removed"
      end
      libraries.each do |library|
        next if library.id == deleted_library.id
        assert Library.exists?(library.id), "unrelated library #{library.id} was removed"
      end
    end
  end

  private

  def next_seq
    @seq += 1
  end

  # Materialize the generated shape into real Library/Artist/Album/Song rows.
  # Returns the created libraries and a flat list of song descriptors capturing
  # each song's id and its library/album/artist associations. Names and hashes
  # are made unique per row to satisfy the library-scoped uniqueness indexes.
  def build_dataset(libraries_spec)
    songs = []

    libraries = libraries_spec.map do |artists_spec|
      library = Library.create!(
        name: "Lib-#{next_seq}",
        kind: "local",
        media_path: MEDIA_PATH,
        owner: @owner
      )

      artists_spec.each do |albums_spec|
        artist = Artist.create!(name: "Artist-#{next_seq}", library: library)

        albums_spec.each do |song_count|
          album = Album.create!(name: "Album-#{next_seq}", artist: artist, library: library)

          song_count.times do
            n = next_seq
            song = Song.create!(
              name: "Song-#{n}",
              file_path: "/tmp/song-#{n}.mp3",
              file_path_hash: "fph-#{n}",
              md5_hash: "md5-#{n}",
              library: library,
              album: album,
              artist: artist
            )

            songs << {
              id: song.id,
              library_id: library.id,
              album_id: album.id,
              artist_id: artist.id
            }
          end
        end
      end

      library
    end

    [ libraries, songs ]
  end
end
