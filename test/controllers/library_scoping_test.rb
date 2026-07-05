# frozen_string_literal: true

require "test_helper"

# Controller-level verification for task 5.3: browse/search/list controllers
# restrict their results to the current User's Active_Library (Req 3.2) and
# return nothing when the User has access to zero Libraries (Req 3.7).
class LibraryScopingTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:visitor1)
    @active_library = libraries(:default_library)
    @other_library = libraries(:secondary_library)
    @other_library.update!(owner: users(:visitor2))

    # A record that lives in a Library the user is NOT browsing. It must never
    # appear in browse/search/list results scoped to the Active_Library.
    @other_artist = Artist.create!(name: "other_library_artist", library: @other_library)
    @other_album = Album.create!(name: "other_library_album", artist: @other_artist, library: @other_library)
    @other_song = Song.create!(
      name: "other_library_song",
      file_path: "/tmp/other_library_song.mp3",
      file_path_hash: "other_library_song_path_hash",
      md5_hash: "other_library_song_md5_hash",
      artist: @other_artist,
      album: @other_album,
      library: @other_library
    )
  end

  test "albums index excludes albums outside the active library (Req 3.2)" do
    get albums_url, as: :json, headers: api_token_header(@user)

    assert_response :success
    ids = @response.parsed_body.map { |item| item["id"] }
    assert_not_includes ids, @other_album.id
    assert_includes ids, albums(:album1).id
  end

  test "artists index excludes artists outside the active library (Req 3.2)" do
    get artists_url, as: :json, headers: api_token_header(@user)

    assert_response :success
    ids = @response.parsed_body.map { |item| item["id"] }
    assert_not_includes ids, @other_artist.id
    assert_includes ids, artists(:artist1).id
  end

  test "songs index excludes songs outside the active library (Req 3.2)" do
    get songs_url, as: :json, headers: api_token_header(@user)

    assert_response :success
    ids = @response.parsed_body.map { |item| item["id"] }
    assert_not_includes ids, @other_song.id
    assert_includes ids, songs(:mp3_sample).id
  end

  test "search excludes content outside the active library (Req 3.2)" do
    get search_url(query: "other_library"), as: :json, headers: api_token_header(@user)

    assert_response :success
    response = @response.parsed_body
    assert_not_includes response["albums"].map { |a| a["id"] }, @other_album.id
    assert_not_includes response["artists"].map { |a| a["id"] }, @other_artist.id
    assert_not_includes response["songs"].map { |s| s["id"] }, @other_song.id
  end

  # A Remote_Library whose Library_Connection is no longer active must stop
  # being served for browsing, searching, and listing once its status becomes
  # `revoked` or `unavailable`, even if it is still the recorded Active_Library
  # (Req 9.2, 11.3). Selection-time authorization only guards the moment of
  # selection; this guards continued browsing after a later status change.
  [ :revoked, :unavailable ].each do |status|
    test "browse/search/list stop serving a #{status} remote mirror that is still the active library (Req 9.2, 11.3)" do
      connection = LibraryConnection.create!(
        user: @user,
        server_base_url: "https://remote.example.com",
        remote_library_id: 77,
        grant_token: "mirror-token",
        status: "active"
      )
      remote_library = Library.create!(
        name: "Mirrored Library",
        kind: "remote",
        library_connection_id: connection.id
      )
      mirror_artist = Artist.create!(name: "mirror_artist", library: remote_library, remote_artist_id: 1)
      mirror_album = Album.create!(name: "mirror_album", artist: mirror_artist, library: remote_library, remote_album_id: 1)
      mirror_song = Song.create!(
        name: "mirror_song",
        artist: mirror_artist,
        album: mirror_album,
        library: remote_library,
        remote_song_id: 1
      )

      # While the connection is active, the mirror is browsable (verified via
      # the albums list to avoid the unrelated remote-song JSON render path).
      @user.update!(active_library: remote_library)

      get albums_url, as: :json, headers: api_token_header(@user)
      assert_response :success
      assert_includes @response.parsed_body.map { |a| a["id"] }, mirror_album.id

      get artists_url, as: :json, headers: api_token_header(@user)
      assert_response :success
      assert_includes @response.parsed_body.map { |a| a["id"] }, mirror_artist.id

      # Once the connection is no longer active, the mirror is excluded from
      # browsing, searching, and listing.
      connection.update!(status: status)

      get songs_url, as: :json, headers: api_token_header(@user)
      assert_response :success
      assert_empty @response.parsed_body

      get albums_url, as: :json, headers: api_token_header(@user)
      assert_response :success
      assert_empty @response.parsed_body

      get artists_url, as: :json, headers: api_token_header(@user)
      assert_response :success
      assert_empty @response.parsed_body

      get search_url(query: "mirror"), as: :json, headers: api_token_header(@user)
      assert_response :success
      assert_empty @response.parsed_body["songs"]
      assert_empty @response.parsed_body["albums"]
      assert_empty @response.parsed_body["artists"]
    end
  end

  test "returns empty results when the user has access to zero libraries (Req 3.7)" do
    # Strip the user's access to every Library: no owned libraries and no
    # recorded Active_Library.
    @active_library.update!(owner: users(:admin))
    @user.update!(active_library: nil)

    get songs_url, as: :json, headers: api_token_header(@user)
    assert_response :success
    assert_empty @response.parsed_body

    get albums_url, as: :json, headers: api_token_header(@user)
    assert_response :success
    assert_empty @response.parsed_body

    get artists_url, as: :json, headers: api_token_header(@user)
    assert_response :success
    assert_empty @response.parsed_body
  end
end
