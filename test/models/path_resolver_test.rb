# frozen_string_literal: true

require "test_helper"

class PathResolverTest < ActiveSupport::TestCase
  include Rails.application.routes.url_helpers

  setup do
    @resolver = PathResolver.new
    @user = users(:visitor1)
    @song = songs(:mp3_sample)
  end

  # ---- Local classification (Req 8.1, 8.4, 8.8, 8.10) ----

  test "classifies a song in a local library as a local stream source" do
    result = @resolver.resolve_stream(@song, user: @user)

    assert_equal "local", result[:stream_source]
  end

  test "resolves a local song to the current-server stream path" do
    result = @resolver.resolve_stream(@song, user: @user)

    assert_equal new_stream_path(song_id: @song.id), result[:resolved_stream_path]
    assert result[:available]
  end

  test "resolves the transcoded stream path when transcoding is required" do
    result = @resolver.resolve_stream(@song, user: @user, transcode: true)

    assert_equal "local", result[:stream_source]
    assert_equal new_transcoded_stream_path(song_id: @song.id), result[:resolved_stream_path]
    assert result[:available]
  end

  test "the default library resolves to a local current-server path (Req 8.8)" do
    assert @song.library.is_default?

    result = @resolver.resolve_stream(@song, user: @user)

    assert_equal "local", result[:stream_source]
    assert_equal new_stream_path(song_id: @song.id), result[:resolved_stream_path]
  end

  # ---- Undeterminable library association (Req 8.9) ----

  test "treats a song with no library association as a local stream source" do
    # A Song whose Library association cannot be determined (`library` resolves
    # to nil) is classified as local (Req 8.9).
    @song.library = nil
    assert_nil @song.library

    result = @resolver.resolve_stream(@song, user: @user)

    assert_equal "local", result[:stream_source]
    assert_equal new_stream_path(song_id: @song.id), result[:resolved_stream_path]
    assert result[:available]
  end

  # ---- Remote classification (Req 8.1, 8.5, 8.10) ----

  test "classifies a song in a remote library with an active connection as remote" do
    song = remote_song(connection_status: :active)

    result = @resolver.resolve_stream(song, user: @user)

    assert_equal "remote", result[:stream_source]
    assert_equal "/stream/remote/#{song.id}", result[:resolved_stream_path]
    assert result[:available]
    assert_not_empty result[:resolved_stream_path]
  end

  # ---- Unresolvable remote connection (Req 8.11) ----

  test "remote song with a revoked connection resolves to an empty path and is unavailable" do
    song = remote_song(connection_status: :revoked)

    result = @resolver.resolve_stream(song, user: @user)

    assert_equal "remote", result[:stream_source]
    assert_equal "", result[:resolved_stream_path]
    assert_not result[:available]
  end

  test "remote song with an unavailable connection resolves to an empty path and is unavailable" do
    song = remote_song(connection_status: :unavailable)

    result = @resolver.resolve_stream(song, user: @user)

    assert_equal "remote", result[:stream_source]
    assert_equal "", result[:resolved_stream_path]
    assert_not result[:available]
  end

  test "remote song whose library has no connection resolves to an empty path and is unavailable" do
    library = create_remote_library(library_connection: nil)
    song = songs(:flac_sample)
    song.update_columns(library_id: library.id)

    result = @resolver.resolve_stream(song.reload, user: @user)

    assert_equal "remote", result[:stream_source]
    assert_equal "", result[:resolved_stream_path]
    assert_not result[:available]
  end

  test "unresolvable remote song preserves the song's other attributes unchanged" do
    song = remote_song(connection_status: :revoked)
    name_before = song.name
    duration_before = song.duration
    album_before = song.album_id

    @resolver.resolve_stream(song, user: @user)

    assert_equal name_before, song.name
    assert_equal duration_before, song.duration
    assert_equal album_before, song.album_id
  end

  # ---- Source_Preference selection for multi-source content (Req 8.13, 11.6, 12.6, 12.7) ----

  test "a song reachable from multiple sources resolves to the preferred copy (Req 8.13, 12.6)" do
    # prefer_own_server (the user's default): the copy in the user's own
    # Local_Library is selected over an accessible remote copy.
    own_copy = make_song(library: libraries(:default_library))
    remote_copy = make_song(library: create_remote_library(library_connection: remote_connection(:active)))
    group_songs(own_copy, remote_copy)

    # Resolving from the remote copy still resolves the preferred own copy.
    result = @resolver.resolve_stream(remote_copy, user: @user)

    assert_equal "local", result[:stream_source]
    assert_equal new_stream_path(song_id: own_copy.id), result[:resolved_stream_path]
    assert result[:available]
  end

  test "falls back to the next available source when the preferred copy is unavailable (Req 11.6, 12.7)" do
    # prefer_highest_quality with no own copy: the highest-quality copy is the
    # remote lossless one, but its connection is revoked (unavailable), so the
    # next available copy is resolved instead.
    @user.update!(source_preference: "prefer_highest_quality")

    unavailable_hi = make_song(
      library: create_remote_library(library_connection: remote_connection(:revoked)),
      bit_depth: 24
    )
    available_lo = make_song(
      library: create_remote_library(library_connection: remote_connection(:active)),
      bit_depth: nil
    )
    group_songs(unavailable_hi, available_lo)

    result = @resolver.resolve_stream(unavailable_hi, user: @user)

    assert_equal "remote", result[:stream_source]
    assert_equal "/stream/remote/#{available_lo.id}", result[:resolved_stream_path]
    assert result[:available]
  end

  test "content with no accessible copy resolves to an empty path and is unavailable (Req 11.9)" do
    revoked_a = make_song(library: create_remote_library(library_connection: remote_connection(:revoked)))
    revoked_b = make_song(library: create_remote_library(library_connection: remote_connection(:unavailable)))
    group_songs(revoked_a, revoked_b)

    result = @resolver.resolve_stream(revoked_a, user: @user)

    assert_equal "remote", result[:stream_source]
    assert_equal "", result[:resolved_stream_path]
    assert_not result[:available]
  end

  test "a song with no duplicate group resolves the passed song unchanged" do
    assert_nil @song.duplicate_group

    result = @resolver.resolve_stream(@song, user: @user)

    assert_equal "local", result[:stream_source]
    assert_equal new_stream_path(song_id: @song.id), result[:resolved_stream_path]
    assert result[:available]
  end

  test "a single-member duplicate group resolves the passed song unchanged" do
    remote_copy = make_song(library: create_remote_library(library_connection: remote_connection(:active)))
    group = DuplicateGroup.create!
    remote_copy.update!(duplicate_group: group)

    result = @resolver.resolve_stream(remote_copy, user: @user)

    assert_equal "remote", result[:stream_source]
    assert_equal "/stream/remote/#{remote_copy.id}", result[:resolved_stream_path]
    assert result[:available]
  end

  # ================= resolve_asset (Req 9.*) =================

  # ---- Local classification (Req 9.1, 9.5) ----

  test "classifies an album in a local library as a local asset source" do
    album = albums(:album1)
    assert album.library.local?

    result = @resolver.resolve_asset(album)

    assert_equal "local", result[:asset_source]
  end

  test "classifies an artist in a local library as a local asset source" do
    artist = artists(:artist1)
    assert artist.library.local?

    result = @resolver.resolve_asset(artist)

    assert_equal "local", result[:asset_source]
  end

  test "treats a record with no library association as a local asset source (Req 9.1)" do
    album = albums(:album1)
    album.library = nil
    assert_nil album.library

    result = @resolver.resolve_asset(album)

    assert_equal "local", result[:asset_source]
  end

  # ---- Local with an existing cover image (Req 9.2, 9.3, 9.5, 9.9) ----

  test "resolves a local album cover image to the current-server proxy path" do
    album = attach_cover_image(albums(:album1))

    result = @resolver.resolve_asset(album)

    assert_equal "local", result[:asset_source]
    assert result[:present]
    assert result[:available]
    assert_not_empty result[:resolved_asset_path]
    assert_equal rails_storage_proxy_path(album.cover_image.variant(:medium), only_path: true), result[:resolved_asset_path]
  end

  test "resolves the requested variant for a local cover image (Req 9.3)" do
    album = attach_cover_image(albums(:album1))

    result = @resolver.resolve_asset(album, variant: :small)

    assert_equal rails_storage_proxy_path(album.cover_image.variant(:small), only_path: true), result[:resolved_asset_path]
  end

  test "coerces an unrecognized variant to the default medium for a local cover image" do
    album = attach_cover_image(albums(:album1))

    result = @resolver.resolve_asset(album, variant: :enormous)

    assert_equal rails_storage_proxy_path(album.cover_image.variant(:medium), only_path: true), result[:resolved_asset_path]
  end

  # ---- No cover image available (Req 9.7) ----

  test "local record with no cover image resolves to an empty path marked absent" do
    album = albums(:album1)
    assert_not album.has_cover_image?

    result = @resolver.resolve_asset(album)

    assert_equal "local", result[:asset_source]
    assert_equal "", result[:resolved_asset_path]
    assert_not result[:present]
  end

  test "remote record with a resolvable connection but no cover image is marked absent (Req 9.7)" do
    album = remote_album(connection_status: :active)
    assert_not album.has_cover_image?

    result = @resolver.resolve_asset(album)

    assert_equal "remote", result[:asset_source]
    assert_equal "", result[:resolved_asset_path]
    assert_not result[:present]
    assert result[:available]
  end

  # ---- Remote classification with a resolvable connection (Req 9.1, 9.4, 9.9) ----

  test "resolves a remote album cover image to the same-origin asset proxy path" do
    album = attach_cover_image(remote_album(connection_status: :active))

    result = @resolver.resolve_asset(album)

    assert_equal "remote", result[:asset_source]
    assert result[:present]
    assert result[:available]
    assert_equal "/asset/remote/albums/#{album.id}", result[:resolved_asset_path]
    assert_not_empty result[:resolved_asset_path]
  end

  test "resolves a remote artist cover image using the artists record type" do
    artist = attach_cover_image(remote_artist(connection_status: :active))

    result = @resolver.resolve_asset(artist)

    assert_equal "remote", result[:asset_source]
    assert_equal "/asset/remote/artists/#{artist.id}", result[:resolved_asset_path]
  end

  test "forwards the requested variant to the remote asset endpoint (Req 9.4)" do
    album = attach_cover_image(remote_album(connection_status: :active))

    result = @resolver.resolve_asset(album, variant: :large)

    assert_equal "/asset/remote/albums/#{album.id}?variant=large", result[:resolved_asset_path]
  end

  # ---- Unresolvable remote connection (Req 9.8) ----

  test "remote album with a revoked connection resolves to an empty path and is unavailable" do
    album = attach_cover_image(remote_album(connection_status: :revoked))

    result = @resolver.resolve_asset(album)

    assert_equal "remote", result[:asset_source]
    assert_equal "", result[:resolved_asset_path]
    assert_not result[:available]
  end

  test "remote album with an unavailable connection resolves to an empty path and is unavailable" do
    album = attach_cover_image(remote_album(connection_status: :unavailable))

    result = @resolver.resolve_asset(album)

    assert_equal "remote", result[:asset_source]
    assert_equal "", result[:resolved_asset_path]
    assert_not result[:available]
  end

  test "remote album whose library has no connection resolves to an empty path and is unavailable" do
    library = create_remote_library(library_connection: nil)
    album = albums(:album2)
    album.update_columns(library_id: library.id)

    result = @resolver.resolve_asset(album.reload)

    assert_equal "remote", result[:asset_source]
    assert_equal "", result[:resolved_asset_path]
    assert_not result[:available]
  end

  test "unresolvable remote record preserves the record's other attributes unchanged (Req 9.8)" do
    album = attach_cover_image(remote_album(connection_status: :revoked))
    name_before = album.name
    year_before = album.year
    artist_before = album.artist_id

    @resolver.resolve_asset(album)

    assert_equal name_before, album.name
    assert_equal year_before, album.year
    assert_equal artist_before, album.artist_id
  end

  private

  # Create a distinct Song in the given library, so a Duplicate_Group can hold
  # several copies of the same logical track across sources.
  def make_song(library:, bit_depth: nil)
    suffix = SecureRandom.hex(4)

    Song.create!(
      name: "dup_#{suffix}",
      file_path: "/tmp/dup_#{suffix}.mp3",
      file_path_hash: "hash_#{suffix}",
      md5_hash: "md5_#{suffix}",
      album: albums(:album1),
      artist: artists(:artist1),
      library: library,
      duration: 8.0,
      bit_depth: bit_depth
    )
  end

  # Group the given songs into one Duplicate_Group (one Logical_Track).
  def group_songs(*songs)
    group = DuplicateGroup.create!
    songs.each { |song| song.update!(duplicate_group: group) }
    group
  end

  def attach_cover_image(record)
    record.cover_image.attach(
      io: File.open(fixtures_file_path("cover_image.jpg")),
      filename: "cover_image.jpg",
      content_type: "image/jpeg"
    )
    record.reload
    record
  end

  def remote_album(connection_status:)
    library = create_remote_library(library_connection: remote_connection(connection_status))
    album = albums(:album2)
    album.update_columns(library_id: library.id)
    album.reload
  end

  def remote_artist(connection_status:)
    library = create_remote_library(library_connection: remote_connection(connection_status))
    artist = artists(:artist2)
    artist.update_columns(library_id: library.id)
    artist.reload
  end

  def remote_connection(connection_status)
    LibraryConnection.create!(
      user: @user,
      server_base_url: "https://remote-#{SecureRandom.hex(4)}.example.com",
      remote_library_id: rand(1..1_000_000),
      grant_token: "remote-bearer-token",
      status: connection_status
    )
  end

  def create_remote_library(library_connection:)
    Library.create!(
      name: "Remote Library #{SecureRandom.hex(4)}",
      kind: :remote,
      owner: @user,
      library_connection: library_connection
    )
  end

  def remote_song(connection_status:)
    connection = LibraryConnection.create!(
      user: @user,
      server_base_url: "https://remote.example.com",
      remote_library_id: 99,
      grant_token: "remote-bearer-token",
      status: connection_status
    )
    library = create_remote_library(library_connection: connection)

    song = songs(:flac_sample)
    song.update_columns(library_id: library.id)
    song.reload
  end
end
