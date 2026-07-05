# frozen_string_literal: true

require "test_helper"

class LibrariesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:visitor1)
    @owned_library = libraries(:default_library) # owner: visitor1, active_library of visitor1
    @other_library = libraries(:secondary_library)
    @other_library.update!(owner: users(:visitor2))
  end

  test "should show library" do
    login
    get library_overview_path

    assert_response :success
  end

  test "index renders successfully as HTML" do
    login(@user)
    get libraries_path

    assert_response :success
  end

  test "index lists the local libraries the user owns and excludes others (Req 3.4)" do
    get libraries_url, as: :json, headers: api_token_header(@user)

    assert_response :success
    ids = @response.parsed_body["libraries"].map { |library| library["id"] }
    assert_includes ids, @owned_library.id
    assert_not_includes ids, @other_library.id
  end

  test "index includes remote libraries reached through an active connection (Req 3.4)" do
    connection = LibraryConnection.create!(
      user: @user,
      server_base_url: "https://remote.example.com",
      remote_library_id: 42,
      grant_token: "secret-token",
      status: "active"
    )
    remote_library = Library.create!(
      name: "Remote Library",
      kind: "remote",
      library_connection_id: connection.id
    )

    get libraries_url, as: :json, headers: api_token_header(@user)

    assert_response :success
    ids = @response.parsed_body["libraries"].map { |library| library["id"] }
    assert_includes ids, remote_library.id
  end

  test "index includes the current Active_Library's content alongside the list (Req 3.8)" do
    get libraries_url, as: :json, headers: api_token_header(@user)

    assert_response :success
    body = @response.parsed_body

    assert_equal @owned_library.id, body["active_library_id"]

    album_ids = body["active_content"]["albums"].map { |album| album["id"] }
    artist_ids = body["active_content"]["artists"].map { |artist| artist["id"] }
    song_ids = body["active_content"]["songs"].map { |song| song["id"] }

    assert_includes album_ids, albums(:album1).id
    assert_includes artist_ids, artists(:artist1).id
    assert_includes song_ids, songs(:mp3_sample).id
  end

  test "index active content is scoped to the Active_Library and excludes other libraries (Req 3.8)" do
    other_artist = Artist.create!(name: "other_library_artist", library: @other_library)
    other_album = Album.create!(name: "other_library_album", artist: other_artist, library: @other_library)
    other_song = Song.create!(
      name: "other_library_song",
      file_path: "/tmp/other_library_song.mp3",
      file_path_hash: "other_library_song_path_hash",
      md5_hash: "other_library_song_md5_hash",
      artist: other_artist,
      album: other_album,
      library: @other_library
    )

    get libraries_url, as: :json, headers: api_token_header(@user)

    assert_response :success
    body = @response.parsed_body

    assert_not_includes body["active_content"]["albums"].map { |a| a["id"] }, other_album.id
    assert_not_includes body["active_content"]["artists"].map { |a| a["id"] }, other_artist.id
    assert_not_includes body["active_content"]["songs"].map { |s| s["id"] }, other_song.id
  end

  test "index returns an empty library list and no active content for a user with zero libraries (Req 3.4, 3.8)" do
    @owned_library.update!(owner: users(:admin))
    @user.update!(active_library: nil)

    get libraries_url, as: :json, headers: api_token_header(@user)

    assert_response :success
    body = @response.parsed_body

    assert_empty body["libraries"]
    assert_nil body["active_library_id"]
    assert_empty body["active_content"]["albums"]
    assert_empty body["active_content"]["artists"]
    assert_empty body["active_content"]["songs"]
  end

  test "create builds a local library owned by the current admin (Req 1.1)" do
    assert_difference -> { Library.count }, 1 do
      post libraries_url,
        params: { library: { name: "New Library", media_path: Rails.root.join("test", "fixtures", "files").to_s, kind: "local" } },
        as: :json,
        headers: api_token_header(users(:admin))
    end

    assert_response :created
    assert_equal "New Library", @response.parsed_body["name"]

    created = Library.find_by(name: "New Library")
    assert_equal users(:admin).id, created.owner_id
    assert created.local?
  end

  test "create returns a validation error for an invalid name (Req 1.1, 1.9)" do
    assert_no_difference -> { Library.count } do
      post libraries_url,
        params: { library: { name: "  ", media_path: Rails.root.join("test", "fixtures", "files").to_s } },
        as: :json,
        headers: api_token_header(users(:admin))
    end

    assert_response :unprocessable_entity
    assert_equal "RecordInvalid", @response.parsed_body["type"]
  end

  test "update renames a library while preserving its content associations (Req 1.5)" do
    song_ids = @owned_library.songs.ids

    patch library_url(@owned_library),
      params: { library: { name: "Renamed Library" } },
      as: :json,
      headers: api_token_header(users(:admin))

    assert_response :success
    assert_equal "Renamed Library", @owned_library.reload.name
    assert_equal song_ids.sort, @owned_library.songs.ids.sort
  end

  test "destroy deletes the library and cascades to its songs (Req 1.6)" do
    library = Library.create!(name: "Disposable Library", kind: "local", media_path: Rails.root.join("test", "fixtures", "files").to_s, owner: users(:admin))
    artist = Artist.create!(name: "disposable_artist", library: library)
    album = Album.create!(name: "disposable_album", artist: artist, library: library)
    song = Song.create!(
      name: "disposable_song",
      file_path: "/tmp/disposable_song.mp3",
      file_path_hash: "disposable_song_path_hash",
      md5_hash: "disposable_song_md5_hash",
      artist: artist,
      album: album,
      library: library
    )

    delete library_url(library), as: :json, headers: api_token_header(users(:admin))

    assert_response :no_content
    assert_not Library.exists?(library.id)
    assert_not Song.exists?(song.id)
  end

  # --- Authorization: only a Server_Owner may create/modify a library (Req 1.8) ---

  test "create/update/destroy are rejected for a non-owner user via api (Req 1.8)" do
    non_owner = @user # visitor1 is authenticated but not a Server_Owner (not admin)

    assert_no_difference -> { Library.count } do
      post libraries_url,
        params: { library: { name: "Unauthorized Library", media_path: Rails.root.join("test", "fixtures", "files").to_s, kind: "local" } },
        as: :json,
        headers: api_token_header(non_owner)
    end
    assert_response :forbidden
    assert_equal "Forbidden", @response.parsed_body["type"]

    patch library_url(@owned_library),
      params: { library: { name: "Renamed By Non Owner" } },
      as: :json,
      headers: api_token_header(non_owner)
    assert_response :forbidden
    assert_equal "Forbidden", @response.parsed_body["type"]
    assert_equal "Default Library", @owned_library.reload.name

    assert_no_difference -> { Library.count } do
      delete library_url(@owned_library), as: :json, headers: api_token_header(non_owner)
    end
    assert_response :forbidden
    assert_equal "Forbidden", @response.parsed_body["type"]
    assert Library.exists?(@owned_library.id)
  end

  test "create/update/destroy are rejected for a non-owner user via HTML (Req 1.8)" do
    login(@user) # non-admin session

    post libraries_url, params: { library: { name: "Unauthorized Library", media_path: Rails.root.join("test", "fixtures", "files").to_s, kind: "local" } }
    assert_response :forbidden

    patch library_url(@owned_library), params: { library: { name: "Renamed By Non Owner" } }
    assert_response :forbidden

    delete library_url(@owned_library)
    assert_response :forbidden
  end

  # --- Rename preserves all content associations (Req 1.5) ---

  test "update rename preserves the library's song, album, and artist associations (Req 1.5)" do
    artist = Artist.create!(name: "preserved_artist", library: @owned_library)
    album = Album.create!(name: "preserved_album", artist: artist, library: @owned_library)
    song = Song.create!(
      name: "preserved_song",
      file_path: "/tmp/preserved_song.mp3",
      file_path_hash: "preserved_song_path_hash",
      md5_hash: "preserved_song_md5_hash",
      artist: artist,
      album: album,
      library: @owned_library
    )

    song_ids = @owned_library.songs.ids
    album_ids = @owned_library.albums.ids
    artist_ids = @owned_library.artists.ids

    patch library_url(@owned_library),
      params: { library: { name: "Renamed Preserving Content" } },
      as: :json,
      headers: api_token_header(users(:admin))

    assert_response :success
    assert_equal "Renamed Preserving Content", @owned_library.reload.name

    assert_equal song_ids.sort, @owned_library.songs.ids.sort
    assert_equal album_ids.sort, @owned_library.albums.ids.sort
    assert_equal artist_ids.sort, @owned_library.artists.ids.sort

    assert_equal @owned_library.id, song.reload.library_id
    assert_equal @owned_library.id, album.reload.library_id
    assert_equal @owned_library.id, artist.reload.library_id
  end

  # --- Delete removes the library's content associations and Access_Grants (Req 1.6) ---

  test "destroy removes the library's content associations and Access_Grants (Req 1.6)" do
    library = Library.create!(name: "Grant Holder Library", kind: "local", media_path: Rails.root.join("test", "fixtures", "files").to_s, owner: users(:admin))
    artist = Artist.create!(name: "grant_artist", library: library)
    album = Album.create!(name: "grant_album", artist: artist, library: library)
    song = Song.create!(
      name: "grant_song",
      file_path: "/tmp/grant_song.mp3",
      file_path_hash: "grant_song_path_hash",
      md5_hash: "grant_song_md5_hash",
      artist: artist,
      album: album,
      library: library
    )
    grant = AccessGrant.create!(library: library, token: "grant-token-1", expires_at: 7.days.from_now)

    delete library_url(library), as: :json, headers: api_token_header(users(:admin))

    assert_response :no_content
    assert_not Library.exists?(library.id)
    assert_not Song.exists?(song.id)
    assert_not Album.exists?(album.id)
    assert_not Artist.exists?(artist.id)
    assert_not AccessGrant.exists?(grant.id)
  end
end
