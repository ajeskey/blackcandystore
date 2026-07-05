# frozen_string_literal: true

require "test_helper"

# Basic request coverage for the remote-stream proxy (Req 6.2, 6.3, 8.5). The
# full cross-server integration coverage lives in task 15.3; these tests stub
# the hosting server with WebMock and assert the proxy's core behavior: it
# forwards audio bytes and Range headers, keeps the grant token server-side, and
# surfaces unavailability when the hosting server fails.
class Stream::RemoteControllerTest < ActionDispatch::IntegrationTest
  HOST_BASE_URL = "https://host.example.com"
  REMOTE_LIBRARY_ID = 77
  # Distinct from the local Song id so the tests prove the proxy keys the
  # hosting endpoint on the stored hosting-side id, not the local id.
  REMOTE_SONG_ID = 4242
  GRANT_TOKEN = "remote-grant-secret-token"

  setup do
    @user = users(:visitor1)
    @connection = LibraryConnection.create!(
      user: @user,
      server_base_url: HOST_BASE_URL,
      remote_library_id: REMOTE_LIBRARY_ID,
      grant_token: GRANT_TOKEN,
      status: :active
    )
    @library = Library.create!(
      name: "Remote Library #{SecureRandom.hex(4)}",
      kind: :remote,
      owner: @user,
      library_connection: @connection
    )
    @song = songs(:flac_sample)
    @song.update_columns(library_id: @library.id, remote_song_id: REMOTE_SONG_ID)
  end

  def stream_endpoint
    "#{HOST_BASE_URL}/federation/libraries/#{REMOTE_LIBRARY_ID}/songs/#{REMOTE_SONG_ID}/stream"
  end

  test "proxies the hosting server's audio bytes to the player" do
    audio_bytes = "ID3\x04\x00remote-audio-content".b

    stub_request(:get, stream_endpoint)
      .with(headers: { "Authorization" => "Bearer #{GRANT_TOKEN}" })
      .to_return(status: 200, body: audio_bytes, headers: { "Content-Type" => "audio/flac" })

    get remote_stream_url(song_id: @song.id), headers: api_token_header(@user)

    assert_response :success
    assert_equal audio_bytes, response.body.b
    assert_equal "audio/flac", response.get_header("Content-Type")
  end

  test "forwards Range headers to the hosting server and preserves partial status" do
    stub = stub_request(:get, stream_endpoint)
      .with(headers: { "Range" => "bytes=0-1023" })
      .to_return(
        status: 206,
        body: "partial".b,
        headers: { "Content-Type" => "audio/flac", "Content-Range" => "bytes 0-1023/2048" }
      )

    get remote_stream_url(song_id: @song.id),
      headers: api_token_header(@user).merge("Range" => "bytes=0-1023")

    assert_requested(stub)
    assert_response :partial_content
    assert_equal "bytes 0-1023/2048", response.get_header("Content-Range")
  end

  test "never exposes the grant token to the client" do
    stub_request(:get, stream_endpoint)
      .to_return(status: 200, body: "audio".b, headers: { "Content-Type" => "audio/flac" })

    get remote_stream_url(song_id: @song.id), headers: api_token_header(@user)

    assert_response :success
    assert_not_includes response.headers.to_s, GRANT_TOKEN
    assert_not_includes response.body, GRANT_TOKEN
  end

  test "returns service unavailable when the hosting server times out" do
    stub_request(:get, stream_endpoint).to_timeout

    get remote_stream_url(song_id: @song.id), headers: api_token_header(@user)

    assert_response :service_unavailable
    assert_equal "RemoteLibraryUnavailable", response.parsed_body["type"]
  end

  test "returns service unavailable when the hosting server rejects the grant" do
    stub_request(:get, stream_endpoint).to_return(status: 403)

    get remote_stream_url(song_id: @song.id), headers: api_token_header(@user)

    assert_response :service_unavailable
    assert_equal "RemoteLibraryUnavailable", response.parsed_body["type"]
  end

  test "returns service unavailable when the connection is revoked" do
    @connection.update!(status: :revoked)

    get remote_stream_url(song_id: @song.id), headers: api_token_header(@user)

    assert_response :service_unavailable
  end

  test "requires authentication" do
    # A JSON request without credentials is rejected as unauthorized; a browser
    # (HTML) request is redirected to the login page. Either way the endpoint is
    # not reachable without a session.
    get remote_stream_url(song_id: @song.id), as: :json

    assert_response :unauthorized
  end
end
