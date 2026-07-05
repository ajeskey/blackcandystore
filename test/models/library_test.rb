# frozen_string_literal: true

require "test_helper"

class LibraryTest < ActiveSupport::TestCase
  # Media-path validation messages (Req 1.3, 1.4, 1.11).
  #
  # A local library must be backed by a media path that exists and is readable.
  # These tests cover the three rejection branches of `media_path_verifiable`
  # and confirm each returns its specific validation error while leaving any
  # existing library untouched.

  def build_library(media_path:, name: "New Library")
    Library.new(name: name, kind: :local, media_path: media_path, owner: users(:admin))
  end

  test "rejects a local library whose media path does not exist with a not-exist error (Req 1.3)" do
    library = build_library(media_path: "/this_path_does_not_exist_#{SecureRandom.hex(8)}")

    assert_not library.valid?
    assert_includes library.errors[:media_path], I18n.t("activerecord.errors.messages.not_exist")
    assert_equal "does not exist", I18n.t("activerecord.errors.messages.not_exist")
  end

  test "rejects a local library whose media path exists but is not readable with an unreadable error (Req 1.4)" do
    create_tmp_dir do |tmp_dir|
      library = build_library(media_path: tmp_dir)

      # The directory exists but is not readable.
      File.stub(:readable?, false) do
        assert_not library.valid?
      end

      assert_includes library.errors[:media_path], I18n.t("activerecord.errors.messages.unreadable")
      assert_equal "is unreadable", I18n.t("activerecord.errors.messages.unreadable")
    end
  end

  test "rejects a local library whose media path existence cannot be confirmed with a not-verifiable error (Req 1.11)" do
    library = build_library(media_path: "/some_media_path")

    # The existence check itself fails or times out.
    File.stub(:exist?, ->(*) { raise Errno::EACCES, "existence check failed" }) do
      assert_not library.valid?
    end

    assert_includes library.errors[:media_path], I18n.t("activerecord.errors.messages.not_verifiable")
    assert_equal "could not be verified", I18n.t("activerecord.errors.messages.not_verifiable")
  end

  test "accepts a local library whose media path exists and is readable" do
    create_tmp_dir do |tmp_dir|
      library = build_library(media_path: tmp_dir)

      assert library.valid?, "expected library with a readable, existing media path to be valid"
    end
  end

  # Library deletion cascade (Req 1.6, 2.4, 2.5).
  #
  # Deleting a local library removes its songs and, reusing the library-scoped
  # `Media.clean_up` semantics, removes an album/artist if and only if no song
  # remains associated with it afterward, while preserving content that belongs
  # to other libraries.

  test "deleting a library removes its songs and the albums/artists left with no songs (Req 2.4)" do
    secondary = libraries(:secondary_library)
    artist = Artist.create!(name: "sec_artist", library: secondary)
    album = Album.create!(name: "sec_album", artist: artist, library: secondary)
    song = Song.create!(
      name: "sec_song",
      file_path: "/tmp/sec_song.mp3",
      file_path_hash: "sec_song_file_path_hash",
      md5_hash: "sec_song_md5_hash",
      artist: artist,
      album: album,
      library: secondary
    )

    secondary.destroy

    assert_nil Song.find_by(id: song.id), "the library's songs must be removed"
    assert_nil Album.find_by(id: album.id), "an album with no remaining songs must be removed"
    assert_nil Artist.find_by(id: artist.id), "an artist with no remaining songs or albums must be removed"
  end

  test "deleting a library preserves content that belongs to other libraries (Req 2.5)" do
    secondary = libraries(:secondary_library)
    Song.create!(
      name: "sec_song",
      file_path: "/tmp/sec_song.mp3",
      file_path_hash: "sec_song_file_path_hash",
      md5_hash: "sec_song_md5_hash",
      artist: Artist.create!(name: "sec_artist", library: secondary),
      album: Album.create!(name: "sec_album", artist: artists(:artist1), library: secondary),
      library: secondary
    )

    default = libraries(:default_library)
    default_song_ids = Song.where(library: default).ids
    default_album_ids = Album.where(library: default).ids
    default_artist_ids = Artist.where(library: default).ids

    secondary.destroy

    assert_equal default_song_ids.sort, Song.where(id: default_song_ids).ids.sort
    assert_equal default_album_ids.sort, Album.where(id: default_album_ids).ids.sort
    assert_equal default_artist_ids.sort, Artist.where(id: default_artist_ids).ids.sort
  end

  test "deleting a library succeeds and removes the library (Req 1.6)" do
    secondary = libraries(:secondary_library)

    assert_nothing_raised { secondary.destroy }
    assert_nil Library.find_by(id: secondary.id)
  end

  test "deleting a library removes its Access_Grants and preserves other libraries' grants (Req 1.6)" do
    secondary = libraries(:secondary_library)
    default = libraries(:default_library)

    secondary_grant = AccessGrant.create!(library: secondary, token: "secondary-grant-token")
    default_grant = AccessGrant.create!(library: default, token: "default-grant-token")

    secondary.destroy

    assert_nil AccessGrant.find_by(id: secondary_grant.id), "the deleted library's grants must be removed"
    assert AccessGrant.exists?(default_grant.id), "another library's grants must be preserved"
  end

  test "rejecting an invalid media path leaves existing libraries unchanged (Req 1.3, 1.4, 1.11)" do
    existing = nil

    create_tmp_dir do |tmp_dir|
      existing = build_library(media_path: tmp_dir, name: "Existing Library")
      assert existing.save, "expected the baseline library to persist"
    end

    original_attributes = existing.reload.attributes
    library_count = Library.count

    # Missing path.
    assert_not build_library(media_path: "/missing_#{SecureRandom.hex(8)}", name: "Missing Path Library").save

    # Unverifiable path.
    File.stub(:exist?, ->(*) { raise Errno::EACCES, "existence check failed" }) do
      assert_not build_library(media_path: "/unverifiable", name: "Unverifiable Path Library").save
    end

    # Unreadable path.
    create_tmp_dir do |tmp_dir|
      File.stub(:readable?, false) do
        assert_not build_library(media_path: tmp_dir, name: "Unreadable Path Library").save
      end
    end

    assert_equal library_count, Library.count, "rejected submissions must not create new libraries"
    assert_equal original_attributes, existing.reload.attributes, "existing library must remain unchanged"
  end
end
