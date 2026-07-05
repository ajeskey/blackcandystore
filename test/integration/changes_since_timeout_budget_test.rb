# frozen_string_literal: true

require "test_helper"

# Integration / smoke tests for the Federation::Client#changes_since network
# path and its timeout budget (remote-library-mirror-sync, task 7.2).
#
# These are NOT property-based tests. They exercise the *network* path the
# redeeming Server's sync engine takes when pulling incremental catalog deltas
# from a hosting Server, asserting the Cross-Server HTTP API Contract for the
# changes endpoint:
#
#   * the request is issued against GET /federation/libraries/:id/changes
#     carrying the Bearer grant credential and the cursor/page query (Req 4.2);
#   * both open_timeout and read_timeout equal the 10s CONTENT_TIMEOUT budget so
#     a slow or dead hosting Server can never hang the sync (Req 10.5);
#   * a 401/403 rejection maps to Unauthorized — the teardown signal (Req 9.4);
#   * a transport failure maps to Timeout (no response within the budget) or
#     Unreachable (connection refused / DNS / socket failure) — the stale signal
#     (Req 10.1).
#
# Every hosting-Server endpoint is stubbed with WebMock (the suite disallows
# real net connections), so we verify the client's behavior against the
# contract without a live peer.
class ChangesSinceTimeoutBudgetTest < ActionDispatch::IntegrationTest
  HOST_BASE_URL = "https://host.example.com"
  REMOTE_LIBRARY_ID = 42
  GRANT_TOKEN = "grant-secret-token"
  CURSOR = 7

  setup do
    @client = Federation::Client.new(base_url: HOST_BASE_URL, grant_token: GRANT_TOKEN)
  end

  # --- 10s content timeout budget (Req 10.5) ---------------------------------

  test "changes_since applies the 10s CONTENT_TIMEOUT to both open and read timeouts" do
    assert_equal 10, Federation::Client::CONTENT_TIMEOUT

    captured = capture_httparty_options { @client.changes_since(REMOTE_LIBRARY_ID, CURSOR) }

    assert_equal Federation::Client::CONTENT_TIMEOUT, captured[:open_timeout],
      "changes_since open_timeout should equal the 10s content budget"
    assert_equal Federation::Client::CONTENT_TIMEOUT, captured[:read_timeout],
      "changes_since read_timeout should equal the 10s content budget"
  end

  test "changes_since targets the changes endpoint with the cursor and page query and the Bearer credential" do
    stub = stub_request(:get, "#{HOST_BASE_URL}/federation/libraries/#{REMOTE_LIBRARY_ID}/changes")
      .with(
        headers: { "Authorization" => "Bearer #{GRANT_TOKEN}" },
        query: { "cursor" => CURSOR.to_s, "page" => "2" }
      )
      .to_return(
        status: 200,
        body: { catalog_version: 12, full_sync_required: false, changes: [] }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    body = @client.changes_since(REMOTE_LIBRARY_ID, CURSOR, 2)

    assert_requested(stub)
    assert_equal 12, body["catalog_version"]
    assert_equal false, body["full_sync_required"]
    assert_equal [], body["changes"]
  end

  test "changes_since defaults to page 1 when no page is supplied" do
    stub = stub_request(:get, "#{HOST_BASE_URL}/federation/libraries/#{REMOTE_LIBRARY_ID}/changes")
      .with(query: { "cursor" => CURSOR.to_s, "page" => "1" })
      .to_return(
        status: 200,
        body: { catalog_version: 12, full_sync_required: false, changes: [] }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    @client.changes_since(REMOTE_LIBRARY_ID, CURSOR)

    assert_requested(stub)
  end

  # --- 403/401 -> Unauthorized (the teardown signal, Req 9.4) ----------------

  test "changes_since raises Unauthorized when the hosting server rejects the grant with 403" do
    stub_request(:get, "#{HOST_BASE_URL}/federation/libraries/#{REMOTE_LIBRARY_ID}/changes")
      .with(query: hash_including({}))
      .to_return(status: 403, body: "forbidden")

    assert_raises(Federation::Client::Unauthorized) do
      @client.changes_since(REMOTE_LIBRARY_ID, CURSOR)
    end
  end

  test "changes_since raises Unauthorized when the hosting server responds with 401" do
    stub_request(:get, "#{HOST_BASE_URL}/federation/libraries/#{REMOTE_LIBRARY_ID}/changes")
      .with(query: hash_including({}))
      .to_return(status: 401, body: "unauthorized")

    assert_raises(Federation::Client::Unauthorized) do
      @client.changes_since(REMOTE_LIBRARY_ID, CURSOR)
    end
  end

  # --- transport failure -> Timeout / Unreachable (the stale signal, Req 10.1)

  test "changes_since raises Timeout when the hosting server does not respond within the budget" do
    stub_request(:get, "#{HOST_BASE_URL}/federation/libraries/#{REMOTE_LIBRARY_ID}/changes")
      .with(query: hash_including({}))
      .to_timeout

    assert_raises(Federation::Client::Timeout) do
      @client.changes_since(REMOTE_LIBRARY_ID, CURSOR)
    end
  end

  test "changes_since raises Unreachable when the connection is refused" do
    stub_request(:get, "#{HOST_BASE_URL}/federation/libraries/#{REMOTE_LIBRARY_ID}/changes")
      .with(query: hash_including({}))
      .to_raise(Errno::ECONNREFUSED)

    assert_raises(Federation::Client::Unreachable) do
      @client.changes_since(REMOTE_LIBRARY_ID, CURSOR)
    end
  end

  test "changes_since raises Unreachable on a DNS/socket failure" do
    stub_request(:get, "#{HOST_BASE_URL}/federation/libraries/#{REMOTE_LIBRARY_ID}/changes")
      .with(query: hash_including({}))
      .to_raise(SocketError)

    assert_raises(Federation::Client::Unreachable) do
      @client.changes_since(REMOTE_LIBRARY_ID, CURSOR)
    end
  end

  private

  # Capture the options Hash the client passes to the underlying HTTParty call
  # so we can assert the timeout budget without a real socket. Returns a
  # successful parseable body so changes_since completes normally.
  def capture_httparty_options
    captured = nil
    fake_response = Struct.new(:code, :body).new(
      200,
      { catalog_version: 0, full_sync_required: false, changes: [] }.to_json
    )

    HTTParty.stub(:get, ->(_url, options) { captured = options; fake_response }) do
      yield
    end

    captured
  end
end
