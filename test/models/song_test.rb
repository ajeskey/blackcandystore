# frozen_string_literal: true

require "test_helper"

class SongTest < ActiveSupport::TestCase
  test "should get file format" do
    assert_equal "mp3", songs(:mp3_sample).format
    assert_equal "flac", songs(:flac_sample).format
    assert_equal "ogg", songs(:ogg_sample).format
    assert_equal "wav", songs(:wav_sample).format
    assert_equal "opus", songs(:opus_sample).format
    assert_equal "m4a", songs(:m4a_sample).format
  end

  test "should remove relative cache files when destroyed" do
    stream = Stream.new(songs(:flac_sample))
    FileUtils.touch(stream.transcode_cache_file_path)
    assert File.exist?(stream.transcode_cache_file_path)

    songs(:flac_sample).destroy
    assert_not File.exist?(stream.transcode_cache_file_path)
  end

  test "should filter by album genre" do
    song_ids = Song.where(album: [ albums(:album1), albums(:album2) ]).ids.sort
    assert_equal song_ids, Song.filter_records(album_genre: "Rock").ids.sort
  end

  test "should filter by album year" do
    song_ids = Song.where(album: albums(:album1)).ids.sort
    assert_equal song_ids, Song.filter_records(album_year: 1984).ids.sort
  end

  test "should filter by multiple attributes" do
    song_ids = Song.where(album: albums(:album1)).ids.sort
    assert_equal song_ids, Song.filter_records(album_genre: "Rock", album_year: 1984).ids.sort
  end

  test "should have valid filter constant" do
    assert_equal %w[album_genre album_year], Song::VALID_FILTERS
  end

  test "should not filter by invalid filter value" do
    assert_equal Song.all.ids.sort, Song.filter_records(invalid: "test").ids.sort
  end

  test "should sort by name" do
    assert_equal songs(:flac_sample), Song.sort_records(:name).first
    assert_equal songs(:wma_sample), Song.sort_records(:name, :desc).first
  end

  test "should sort by created_at" do
    assert_equal songs(:flac_sample), Song.sort_records(:created_at).first
    assert_equal songs(:wma_sample), Song.sort_records(:created_at, :desc).first
  end

  test "should sort by artist name" do
    assert_equal songs(:mp3_sample), Song.sort_records(:artist_name).first
    assert_equal songs(:ogg_sample), Song.sort_records(:artist_name, :desc).first
  end

  test "should sort by album name" do
    assert_equal songs(:flac_sample), Song.sort_records(:album_name).first
    assert_equal songs(:various_artists_sample), Song.sort_records(:album_name, :desc).first
  end

  test "should sort by album year" do
    assert_equal songs(:various_artists_sample).name, Song.sort_records(:album_year).first.name
    assert_equal songs(:mp3_sample), Song.sort_records(:album_year, :desc).first
  end

  test "should sort by name by default" do
    assert_equal songs(:flac_sample), Song.sort_records.first
  end

  test "should get sort options" do
    assert_equal %w[name created_at artist_name album_name album_year], Song::SORT_OPTION.values
    assert_equal "name", Song::SORT_OPTION.default.name
    assert_equal "asc", Song::SORT_OPTION.default.direction
  end

  test "should use default sort when use invalid sort value" do
    assert_equal songs(:flac_sample), Song.sort_records(:invalid).first
  end

  test "should get unique error when create song with same md5_hash in the same library" do
    existing = songs(:flac_sample)

    song = Song.new(
      name: "song_test",
      file_path: Rails.root.join("test/fixtures/files/artist1_album2.mp3"),
      file_path_hash: "fake_path_hash",
      md5_hash: existing.md5_hash,
      library_id: existing.library_id,
      artist_id: artists(:artist1).id,
      album_id: albums(:album1).id
    )

    assert_raise ActiveRecord::RecordNotUnique do
      song.save
    end
  end

  test "should allow same md5_hash in different libraries" do
    existing = songs(:flac_sample)

    song = Song.new(
      name: "song_test",
      file_path: Rails.root.join("test/fixtures/files/artist1_album2.mp3"),
      file_path_hash: "fake_path_hash",
      md5_hash: existing.md5_hash,
      library_id: libraries(:secondary_library).id,
      artist_id: artists(:artist1).id,
      album_id: albums(:album1).id
    )

    assert_nothing_raised do
      song.save!
    end
  end

  # A Mirrored_Song lives in a Remote_Library and stores no local file, so the
  # file-backed columns are not required (metadata-only mirror, Req 1.4). The
  # presence validations are conditioned on `library&.local?` (Req 1.2).
  test "should be valid in a remote library with no file_path, file_path_hash, or md5_hash" do
    library = remote_library
    song = Song.new(
      name: "mirrored_song",
      library: library,
      artist: remote_artist(library),
      album: remote_album(library),
      duration: 8.0
    )

    assert_nil song.file_path
    assert_nil song.file_path_hash
    assert_nil song.md5_hash
    assert song.valid?, "expected a remote-library song without file columns to be valid, got: #{song.errors.full_messages.inspect}"
  end

  # Local-library songs are unaffected by the conditional relaxation: all three
  # file-backed columns remain required, preserving existing behavior (Req 1.2).
  test "should require file_path, file_path_hash, and md5_hash in a local library" do
    song = Song.new(
      name: "local_song",
      library: libraries(:default_library),
      artist: artists(:artist1),
      album: albums(:album1),
      duration: 8.0
    )

    assert_not song.valid?, "expected a local-library song without file columns to be invalid"
    assert_includes song.errors.attribute_names, :file_path
    assert_includes song.errors.attribute_names, :file_path_hash
    assert_includes song.errors.attribute_names, :md5_hash
  end

  private

  def remote_library
    connection = LibraryConnection.create!(
      user: users(:visitor1),
      server_base_url: "https://remote.example.com",
      remote_library_id: 99,
      grant_token: "remote-bearer-token",
      status: :active
    )

    Library.create!(
      name: "Remote Library #{SecureRandom.hex(4)}",
      kind: :remote,
      owner: users(:visitor1),
      library_connection: connection
    )
  end

  def remote_artist(library)
    Artist.create!(name: "remote_artist_#{SecureRandom.hex(4)}", library: library)
  end

  def remote_album(library)
    Album.create!(name: "remote_album_#{SecureRandom.hex(4)}", library: library, artist: remote_artist(library))
  end
end
