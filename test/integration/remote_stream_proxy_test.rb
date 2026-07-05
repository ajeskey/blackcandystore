# frozen_string_literal: true

require "test_helper"

# Integration / smoke test for the remote-stream proxy network path
# (multi-server-library-sharing, task 15.3).
#
# Unlike the property tests in this feature, this exercises the full request
# cycle a player takes to stream a Song that lives in a Remote_Library:
#
#   Web_Player / App_Player --GET /stream/remote/:song_id--> redeeming Server
#     redeeming Server --GET /federation/.../stream (Bearer grant)--> hosting Server
#       hosting Server --audio bytes--> redeeming Server --audio bytes--> player
#
# Every hosting-Server endpoint is stubbed with WebMock (the suite disallows
# real net connections), so we verify the redeeming Server's proxy behavior
# against the Cross-Server HTTP API Contract without a live peer:
#
#   * streams the hosting Server's bytes end-to-end to the player   (Req 6.2)
#   * presents the Library_Connection's stored credential to the
#     hosting Server but never exposes it to the player             (Req 6.2)
#   * surfaces the Remote_Library as unavailable on a 10s timeout,
#     retaining the Library_Connection unchanged                    (Req 6.3)
#
# This complements the request-level coverage in
# test/controllers/stream/remote_controller_test.rb: those tests assert the
# controller's individual behaviors, while these assert the end-to-end network
# path (outbound credential presentation, byte-exact delivery of a full body,
# and connection state retention across a failure).
#
# These are NOT property-based tests — they are example/smoke tests of the
# cross-server request/response and failure translation behavior.
class RemoteStreamProxyTest < ActionDispatch::IntegrationTest
  # A distinct hosting Server host so the Song resolves down the remote path.
  HOST_BASE_URL = "https://remote-host.example.com"
  REMOTE_LIBRARY_ID = 314
  # Distinct from the local Song id so the proxy is proven to key the hosting
  # endpoint on the stored hosting-side id rather than the local id.
  REMOTE_SONG_ID = 9001
  GRANT_TOKEN = "super-secret-grant-token-abc123"

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

  # The hosting Server's federation stream endpoint the proxy reaches through
  # the Library_Connection.
  def hosting_stream_endpoint
    "#{HOST_BASE_URL}/federation/libraries/#{REMOTE_LIBRARY_ID}/songs/#{REMOTE_SONG_ID}/stream"
  end

  # --- streams hosting bytes end-to-end (Req 6.2) ----------------------------

  test "streams the hosting server's audio bytes end-to-end to the player" do
    # A full, non-trivial binary body to prove the proxy forwards the complete
    # payload byte-for-byte rather than a truncated/re-encoded version.
    audio_bytes = ("fLaC\x00\x00\x00\x22".b + SecureRandom.bytes(4096)).b

    hosting = stub_request(:get, hosting_stream_endpoint)
      .with(headers: { "Authorization" => "Bearer #{GRANT_TOKEN}" })
      .to_return(
        status: 200,
        body: audio_bytes,
        headers: { "Content-Type" => "audio/flac", "Accept-Ranges" => "bytes" }
      )

    get remote_stream_url(song_id: @song.id), headers: api_token_header(@user)

    # The redeeming Server actually reached the hosting Server with the grant.
    assert_requested(hosting)
    assert_response :success
    # Byte-exact, full-length delivery to the player.
    assert_equal audio_bytes, response.body.b
    assert_equal audio_bytes.bytesize, response.body.b.bytesize
    assert_equal "audio/flac", response.get_header("Content-Type")
    assert_equal "bytes", response.get_header("Accept-Ranges")
  end

  test "forwards Range requests end-to-end and preserves partial-content metadata" do
    partial_bytes = SecureRandom.bytes(1024)

    hosting = stub_request(:get, hosting_stream_endpoint)
      .with(headers: { "Authorization" => "Bearer #{GRANT_TOKEN}", "Range" => "bytes=0-1023" })
      .to_return(
        status: 206,
        body: partial_bytes,
        headers: {
          "Content-Type" => "audio/flac",
          "Content-Range" => "bytes 0-1023/8192",
          "Accept-Ranges" => "bytes"
        }
      )

    get remote_stream_url(song_id: @song.id),
      headers: api_token_header(@user).merge("Range" => "bytes=0-1023")

    assert_requested(hosting)
    assert_response :partial_content
    assert_equal partial_bytes, response.body.b
    assert_equal "bytes 0-1023/8192", response.get_header("Content-Range")
    assert_equal "bytes", response.get_header("Accept-Ranges")
  end

  # --- credentials stay server-side (Req 6.2) --------------------------------

  test "presents the stored credential to the hosting server but never exposes it to the player" do
    hosting = stub_request(:get, hosting_stream_endpoint)
      .with(headers: { "Authorization" => "Bearer #{GRANT_TOKEN}" })
      .to_return(status: 200, body: "audio".b, headers: { "Content-Type" => "audio/flac" })

    get remote_stream_url(song_id: @song.id), headers: api_token_header(@user)

    # The grant token WAS used server-side to authenticate to the hosting
    # Server...
    assert_requested(hosting)
    assert_response :success

    # ...but is NEVER leaked back to the player, in any response header
    # (including any Authorization/Location echo) or in the body.
    assert_not_includes response.headers.to_s, GRANT_TOKEN
    assert_not_includes response.body, GRANT_TOKEN
    assert_nil response.get_header("Authorization")
  end

  test "does not accept a client-supplied grant token to reach the hosting server" do
    # The player has no way to inject or override the credential: the proxy
    # always uses the server-side Library_Connection token. A bogus client
    # Authorization override must not change the Bearer token sent upstream.
    hosting = stub_request(:get, hosting_stream_endpoint)
      .with(headers: { "Authorization" => "Bearer #{GRANT_TOKEN}" })
      .to_return(status: 200, body: "audio".b, headers: { "Content-Type" => "audio/flac" })

    get remote_stream_url(song_id: @song.id), headers: api_token_header(@user)

    assert_requested(hosting)
    # A request presenting any other Bearer token to the hosting Server would
    # not have matched the stub above.
    assert_response :success
  end

  # --- unavailability on timeout (Req 6.3) -----------------------------------

  test "surfaces the remote library as unavailable when the hosting server times out" do
    stub_request(:get, hosting_stream_endpoint).to_timeout

    get remote_stream_url(song_id: @song.id), headers: api_token_header(@user)

    assert_response :service_unavailable
    assert_equal "RemoteLibraryUnavailable", response.parsed_body["type"]
  end

  test "retains the library connection unchanged after a timeout" do
    stub_request(:get, hosting_stream_endpoint).to_timeout

    assert_no_changes -> { @connection.reload.attributes } do
      get remote_stream_url(song_id: @song.id), headers: api_token_header(@user)
    end

    assert_response :service_unavailable
    assert @connection.reload.active?, "connection should remain active after a transient timeout"
  end

  # --- unavailability when access is revoked mid-use (Req 6.3, cross-check) ---

  test "surfaces unavailability when the hosting server rejects the grant mid-use" do
    stub_request(:get, hosting_stream_endpoint).to_return(status: 403, body: "access revoked")

    get remote_stream_url(song_id: @song.id), headers: api_token_header(@user)

    assert_response :service_unavailable
    assert_equal "RemoteLibraryUnavailable", response.parsed_body["type"]
  end

  # ==========================================================================
  # Task 15.3 — live audio proxy contract (Req 7.2, 7.3)
  #
  # These assert the three guarantees task 15.3 calls out explicitly: the proxy
  # keys the hosting endpoint on the STORED Remote_Song_Id (not the local Song
  # id), it forwards HTTP range headers up to the host, and an unavailable host
  # yields an immediate 503 with NO stored-bytes fallback.
  # ==========================================================================

  # The endpoint the host would be hit at if the proxy (incorrectly) keyed on
  # the LOCAL Song id instead of the stored Remote_Song_Id.
  def local_id_stream_endpoint
    "#{HOST_BASE_URL}/federation/libraries/#{REMOTE_LIBRARY_ID}/songs/#{@song.id}/stream"
  end

  # --- keys the hosting endpoint on the stored Remote_Song_Id (Req 7.2) ------

  test "proxies via the stored remote_song_id, never the local song id" do
    # The local Song id and the stored hosting-side id are deliberately
    # different, so a proxy that keyed on the wrong one would hit a different
    # URL. Guard against that regression directly.
    assert_not_equal @song.id, REMOTE_SONG_ID, "test fixture must use distinct local/remote ids"

    remote = stub_request(:get, hosting_stream_endpoint)
      .with(headers: { "Authorization" => "Bearer #{GRANT_TOKEN}" })
      .to_return(status: 200, body: "audio".b, headers: { "Content-Type" => "audio/flac" })
    local = stub_request(:get, local_id_stream_endpoint)
      .to_return(status: 200, body: "WRONG".b, headers: { "Content-Type" => "audio/flac" })

    get remote_stream_url(song_id: @song.id), headers: api_token_header(@user)

    assert_response :success
    # Keyed on the stored hosting-side id...
    assert_requested(remote)
    # ...and never on the local Song id.
    assert_not_requested(local)
  end

  # --- forwards range request headers to the host (Req 7.2) ------------------

  test "forwards the If-Range request header to the hosting server" do
    etag = '"host-side-etag-v1"'

    hosting = stub_request(:get, hosting_stream_endpoint)
      .with(headers: {
        "Authorization" => "Bearer #{GRANT_TOKEN}",
        "Range" => "bytes=2048-4095",
        "If-Range" => etag
      })
      .to_return(
        status: 206,
        body: SecureRandom.bytes(2048),
        headers: {
          "Content-Type" => "audio/flac",
          "Content-Range" => "bytes 2048-4095/8192",
          "Accept-Ranges" => "bytes"
        }
      )

    get remote_stream_url(song_id: @song.id),
      headers: api_token_header(@user).merge("Range" => "bytes=2048-4095", "If-Range" => etag)

    # The stub only matches if BOTH range headers were forwarded upstream.
    assert_requested(hosting)
    assert_response :partial_content
    assert_equal "bytes 2048-4095/8192", response.get_header("Content-Range")
  end

  # --- 503 with no fallback across the unavailability matrix (Req 7.3) -------

  # Every way the host can be "unavailable" must produce an immediate 503 whose
  # body is the unavailable payload, never any audio bytes. Parameterized over
  # the transport/HTTP failure modes the design enumerates.
  {
    "read timeout" => ->(stub) { stub.to_timeout },
    "connection refused" => ->(stub) { stub.to_raise(Errno::ECONNREFUSED) },
    "unauthorized (401)" => ->(stub) { stub.to_return(status: 401, body: "nope") },
    "forbidden (403)" => ->(stub) { stub.to_return(status: 403, body: "revoked") },
    "server error (500)" => ->(stub) { stub.to_return(status: 500, body: "boom") },
    "bad gateway (502)" => ->(stub) { stub.to_return(status: 502, body: "bad gateway") },
    "gateway unavailable (503)" => ->(stub) { stub.to_return(status: 503, body: "down") }
  }.each do |scenario, apply_failure|
    test "returns 503 with no stored-bytes fallback when the host is unavailable: #{scenario}" do
      apply_failure.call(stub_request(:get, hosting_stream_endpoint))

      get remote_stream_url(song_id: @song.id), headers: api_token_header(@user)

      # Immediate failure...
      assert_response :service_unavailable
      assert_equal "RemoteLibraryUnavailable", response.parsed_body["type"]
      # ...and NO fallback to any cached/stored audio: the only content is the
      # unavailable JSON payload, never audio bytes.
      assert_equal "application/json", response.media_type
      assert_nil response.get_header("Accept-Ranges")
    end
  end
end
