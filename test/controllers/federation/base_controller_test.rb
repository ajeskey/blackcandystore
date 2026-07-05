# frozen_string_literal: true

require "test_helper"

module Federation
  # Request tests for the hosting-side federation API. These exercise the
  # controllers end-to-end with a real Access_Grant token presented as a Bearer
  # credential. The full cross-server (WebMock stubbed) integration path is
  # covered separately in task 10.3.
  class BaseControllerTest < ActionDispatch::IntegrationTest
    setup do
      @library = libraries(:default_library)
      @token = "federation-test-token-abc123"
      @grant = AccessGrant.create!(
        library: @library,
        token: @token,
        expires_at: 1.day.from_now
      )
    end

    def bearer(token = @token)
      { authorization: "Bearer #{token}" }
    end

    # --- ping ---

    test "ping returns 200" do
      get federation_ping_url
      assert_response :ok
    end

    # --- grants#confirm ---

    test "confirm returns library and valid true for a good grant" do
      post federation_grants_confirm_url,
        params: { library_id: @library.id },
        headers: bearer,
        as: :json

      assert_response :success
      body = @response.parsed_body
      assert_equal @library.id, body["library"]["id"]
      assert_equal @library.name, body["library"]["name"]
      assert_equal true, body["valid"]
    end

    test "confirm rejects an unknown token with 403" do
      post federation_grants_confirm_url,
        params: { library_id: @library.id },
        headers: bearer("does-not-exist"),
        as: :json

      assert_response :forbidden
    end

    test "confirm rejects when the grant references a different library" do
      other = libraries(:secondary_library)

      post federation_grants_confirm_url,
        params: { library_id: other.id },
        headers: bearer,
        as: :json

      assert_response :forbidden
    end

    test "confirm rejects a revoked grant" do
      @grant.update!(status: :revoked)

      post federation_grants_confirm_url,
        params: { library_id: @library.id },
        headers: bearer,
        as: :json

      assert_response :forbidden
    end

    test "confirm rejects an expired grant" do
      @grant.update!(expires_at: 1.day.ago)

      post federation_grants_confirm_url,
        params: { library_id: @library.id },
        headers: bearer,
        as: :json

      assert_response :forbidden
    end

    test "confirm without any token is rejected" do
      post federation_grants_confirm_url, params: { library_id: @library.id }, as: :json
      assert_response :forbidden
    end

    # --- libraries#songs / albums / artists ---

    test "songs returns only the authorized local library content" do
      get federation_library_songs_url(library_id: @library.id), headers: bearer, as: :json

      assert_response :success
      ids = @response.parsed_body.map { |s| s["id"] }
      expected = Song.where(library_id: @library.id).ids
      assert_equal expected.sort, ids.sort
      refute_empty ids
    end

    test "songs is rejected without a valid grant" do
      get federation_library_songs_url(library_id: @library.id), headers: bearer("nope"), as: :json
      assert_response :forbidden
    end

    test "albums returns the library albums" do
      get federation_library_albums_url(library_id: @library.id), headers: bearer, as: :json

      assert_response :success
      ids = @response.parsed_body.map { |a| a["id"] }
      assert_equal Album.where(library_id: @library.id).ids.sort, ids.sort
    end

    test "artists returns the library artists" do
      get federation_library_artists_url(library_id: @library.id), headers: bearer, as: :json

      assert_response :success
      ids = @response.parsed_body.map { |a| a["id"] }
      assert_equal Artist.where(library_id: @library.id).ids.sort, ids.sort
    end

    # --- songs#stream ---

    test "stream returns the audio bytes for an authorized song" do
      song = songs(:mp3_sample)

      get federation_library_song_stream_url(library_id: @library.id, song_id: song.id),
        headers: bearer

      assert_response :success
      assert_equal binary_data(file_fixture("artist1_album2.mp3")), response.body
    end

    test "stream is rejected without a valid grant" do
      song = songs(:mp3_sample)

      get federation_library_song_stream_url(library_id: @library.id, song_id: song.id),
        headers: bearer("bad")

      assert_response :forbidden
    end

    # --- assets#show ---

    test "album asset returns not found when there is no cover image" do
      album = albums(:album1)

      get federation_library_album_asset_url(library_id: @library.id, id: album.id),
        headers: bearer

      assert_response :not_found
    end

    test "album asset is rejected without a valid grant" do
      album = albums(:album1)

      get federation_library_album_asset_url(library_id: @library.id, id: album.id),
        headers: bearer("bad")

      assert_response :forbidden
    end
  end
end
