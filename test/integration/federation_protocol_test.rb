# frozen_string_literal: true

require "test_helper"

# Integration / smoke tests for the cross-server federation protocol path
# (multi-server-library-sharing, task 10.3).
#
# Unlike the property tests in this feature, these exercise the *network* path a
# redeeming Server takes against a hosting Server. Every hosting-Server endpoint
# is stubbed with WebMock (the suite disallows real net connections), so we
# verify how `Federation::Client` and `InviteManager.redeem` behave against the
# Cross-Server HTTP API Contract without a live peer:
#
#   * grant confirmation           POST /federation/grants/confirm   (Req 5.2)
#   * remote browse                GET  /federation/libraries/:id/... (Req 6.1)
#   * remote stream                GET  .../songs/:id/stream          (Req 6.2)
#   * remote asset fetch           GET  .../{albums,artists}/:id/asset (Req 9.4, 9.6)
#   * 30s redemption timeout       confirm endpoint times out         (Req 5.7)
#   * 10s content timeout          content endpoint times out         (Req 6.3)
#   * revocation surfaced mid-use  content endpoint returns 403       (Req 6.7)
#
# These are NOT property-based tests — they are example/smoke tests of the
# cross-server request/response and failure translation behavior.
class FederationProtocolTest < ActionDispatch::IntegrationTest
  # The hosting Server the redeeming Server talks to. A distinct host (not the
  # configured `server_base_url`) so redemption routes down the cross-server
  # path rather than the local path.
  HOST_BASE_URL = "https://host.example.com"
  REMOTE_LIBRARY_ID = 42
  GRANT_TOKEN = "grant-secret-token"

  setup do
    @user = users(:visitor2)
    @client = Federation::Client.new(base_url: HOST_BASE_URL, grant_token: GRANT_TOKEN)
  end

  # --- grant confirmation (Req 5.2) ------------------------------------------

  test "confirm_grant returns the parsed confirmation body on success" do
    stub_request(:post, "#{HOST_BASE_URL}/federation/grants/confirm")
      .with(
        headers: { "Authorization" => "Bearer #{GRANT_TOKEN}" },
        body: { library_id: REMOTE_LIBRARY_ID }.to_json
      )
      .to_return(
        status: 200,
        body: { library: { id: REMOTE_LIBRARY_ID, name: "Shared Library" }, valid: true }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    body = @client.confirm_grant(REMOTE_LIBRARY_ID)

    assert_equal true, body["valid"]
    assert_equal REMOTE_LIBRARY_ID, body.dig("library", "id")
    assert_equal "Shared Library", body.dig("library", "name")
  end

  test "confirm_grant raises Unauthorized when the hosting server rejects the grant with 403" do
    stub_request(:post, "#{HOST_BASE_URL}/federation/grants/confirm")
      .to_return(status: 403, body: "")

    assert_raises(Federation::Client::Unauthorized) do
      @client.confirm_grant(REMOTE_LIBRARY_ID)
    end
  end

  # --- remote browse (Req 6.1) -----------------------------------------------

  test "browse returns the remote library's songs list" do
    songs = [
      { "id" => 1, "name" => "Remote Song A" },
      { "id" => 2, "name" => "Remote Song B" }
    ]
    stub_request(:get, "#{HOST_BASE_URL}/federation/libraries/#{REMOTE_LIBRARY_ID}/songs")
      .with(headers: { "Authorization" => "Bearer #{GRANT_TOKEN}" })
      .to_return(
        status: 200,
        body: songs.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    assert_equal songs, @client.browse(REMOTE_LIBRARY_ID, :songs)
  end

  test "browse returns the remote library's albums and artists lists" do
    albums = [ { "id" => 10, "name" => "Remote Album" } ]
    artists = [ { "id" => 20, "name" => "Remote Artist" } ]

    stub_request(:get, "#{HOST_BASE_URL}/federation/libraries/#{REMOTE_LIBRARY_ID}/albums")
      .to_return(status: 200, body: albums.to_json, headers: { "Content-Type" => "application/json" })
    stub_request(:get, "#{HOST_BASE_URL}/federation/libraries/#{REMOTE_LIBRARY_ID}/artists")
      .to_return(status: 200, body: artists.to_json, headers: { "Content-Type" => "application/json" })

    assert_equal albums, @client.browse(REMOTE_LIBRARY_ID, :albums)
    assert_equal artists, @client.browse(REMOTE_LIBRARY_ID, :artists)
  end

  test "browse forwards pagination query parameters to the hosting server" do
    stub = stub_request(:get, "#{HOST_BASE_URL}/federation/libraries/#{REMOTE_LIBRARY_ID}/songs")
      .with(query: { "page" => "2", "per_page" => "50" })
      .to_return(status: 200, body: [].to_json, headers: { "Content-Type" => "application/json" })

    @client.browse(REMOTE_LIBRARY_ID, :songs, page: 2, per_page: 50)

    assert_requested(stub)
  end

  # --- remote stream (Req 6.2) -----------------------------------------------

  test "stream returns the raw audio bytes from the hosting server" do
    audio_bytes = "ID3\x04\x00binary-audio-content".b

    stub_request(:get, "#{HOST_BASE_URL}/federation/libraries/#{REMOTE_LIBRARY_ID}/songs/7/stream")
      .with(headers: { "Authorization" => "Bearer #{GRANT_TOKEN}" })
      .to_return(status: 200, body: audio_bytes, headers: { "Content-Type" => "audio/mpeg" })

    response = @client.stream(REMOTE_LIBRARY_ID, 7)

    assert_equal 200, response.code
    assert_equal audio_bytes, response.body.b
  end

  test "stream forwards Range headers to the hosting server" do
    stub = stub_request(:get, "#{HOST_BASE_URL}/federation/libraries/#{REMOTE_LIBRARY_ID}/songs/7/stream")
      .with(headers: { "Range" => "bytes=0-1023" })
      .to_return(status: 206, body: "partial".b)

    @client.stream(REMOTE_LIBRARY_ID, 7, { "Range" => "bytes=0-1023" })

    assert_requested(stub)
  end

  # --- remote asset fetch (Req 9.4, 9.6) -------------------------------------

  test "asset returns the raw cover image bytes for an album" do
    image_bytes = "\x89PNG\r\n\x1a\nfake-cover-image".b

    stub_request(:get, "#{HOST_BASE_URL}/federation/libraries/#{REMOTE_LIBRARY_ID}/albums/3/asset")
      .with(headers: { "Authorization" => "Bearer #{GRANT_TOKEN}" })
      .to_return(status: 200, body: image_bytes, headers: { "Content-Type" => "image/png" })

    response = @client.asset(REMOTE_LIBRARY_ID, :albums, 3)

    assert_equal 200, response.code
    assert_equal image_bytes, response.body.b
  end

  test "asset forwards the variant selector for an artist image" do
    stub = stub_request(:get, "#{HOST_BASE_URL}/federation/libraries/#{REMOTE_LIBRARY_ID}/artists/5/asset")
      .with(query: { "variant" => "thumb" })
      .to_return(status: 200, body: "artist-image".b, headers: { "Content-Type" => "image/jpeg" })

    @client.asset(REMOTE_LIBRARY_ID, :artists, 5, variant: "thumb")

    assert_requested(stub)
  end

  # --- 30s redemption timeout (Req 5.7) --------------------------------------

  test "redeem raises ServerUnavailable and creates no connection when confirmation times out" do
    stub_request(:post, "#{HOST_BASE_URL}/federation/grants/confirm").to_timeout

    assert_no_difference -> { LibraryConnection.count } do
      assert_raises(InviteManager::ServerUnavailable) do
        InviteManager.redeem(invite_code: remote_invite_code(GRANT_TOKEN), user: @user)
      end
    end
  end

  test "confirm_grant raises Timeout directly when the confirmation endpoint times out" do
    stub_request(:post, "#{HOST_BASE_URL}/federation/grants/confirm").to_timeout

    assert_raises(Federation::Client::Timeout) do
      @client.confirm_grant(REMOTE_LIBRARY_ID)
    end
  end

  # --- 10s content timeout (Req 6.3) -----------------------------------------

  test "stream raises Timeout when the hosting content endpoint does not respond in time" do
    stub_request(:get, "#{HOST_BASE_URL}/federation/libraries/#{REMOTE_LIBRARY_ID}/songs/7/stream")
      .to_timeout

    assert_raises(Federation::Client::Timeout) do
      @client.stream(REMOTE_LIBRARY_ID, 7)
    end
  end

  test "browse raises Timeout when the hosting content endpoint does not respond in time" do
    stub_request(:get, "#{HOST_BASE_URL}/federation/libraries/#{REMOTE_LIBRARY_ID}/albums")
      .to_timeout

    assert_raises(Federation::Client::Timeout) do
      @client.browse(REMOTE_LIBRARY_ID, :albums)
    end
  end

  # --- revocation surfaced mid-use (Req 6.7) ---------------------------------

  test "stream raises Unauthorized when the hosting server revokes access mid-use with 403" do
    stub_request(:get, "#{HOST_BASE_URL}/federation/libraries/#{REMOTE_LIBRARY_ID}/songs/7/stream")
      .to_return(status: 403, body: "access revoked")

    assert_raises(Federation::Client::Unauthorized) do
      @client.stream(REMOTE_LIBRARY_ID, 7)
    end
  end

  test "asset raises Unauthorized when the hosting server revokes access mid-use with 401" do
    stub_request(:get, "#{HOST_BASE_URL}/federation/libraries/#{REMOTE_LIBRARY_ID}/albums/3/asset")
      .to_return(status: 401, body: "unauthorized")

    assert_raises(Federation::Client::Unauthorized) do
      @client.asset(REMOTE_LIBRARY_ID, :albums, 3)
    end
  end

  private

  # Encode an Invite_Code pointing at the stubbed hosting Server so redemption
  # routes down the cross-server path (base URL differs from this Server's).
  def remote_invite_code(token)
    InviteManager.encode(server_base_url: HOST_BASE_URL, secret_token: token)
  end
end
