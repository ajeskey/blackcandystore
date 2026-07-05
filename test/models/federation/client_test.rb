# frozen_string_literal: true

require "test_helper"

# Unit tests for Federation::Client focused on the two things this task owns:
# timeout configuration and translation of transport/HTTP failures into domain
# exceptions. The full protocol path (grant confirm, browse, stream, asset over
# a stubbed hosting server) is covered by the separate integration task (10.3).
class Federation::ClientTest < ActiveSupport::TestCase
  BASE_URL = "https://host.example.com"
  TOKEN = "grant-token-abc123"

  setup do
    @client = Federation::Client.new(base_url: "#{BASE_URL}/", grant_token: TOKEN)
  end

  test "sends the grant token as a Bearer credential" do
    stub = stub_request(:get, "#{BASE_URL}/federation/ping")
      .with(headers: { "Authorization" => "Bearer #{TOKEN}" })
      .to_return(status: 200, body: "")

    assert @client.ping
    assert_requested(stub)
  end

  test "confirm_grant posts the library id and returns the parsed body" do
    stub = stub_request(:post, "#{BASE_URL}/federation/grants/confirm")
      .with(
        headers: { "Authorization" => "Bearer #{TOKEN}" },
        body: { library_id: 7 }.to_json
      )
      .to_return(status: 200, body: { library: { id: 7, name: "Shared" }, valid: true }.to_json)

    body = @client.confirm_grant(7)
    assert_requested(stub)
    assert_equal true, body["valid"]
    assert_equal "Shared", body.dig("library", "name")
  end

  test "confirm_grant applies the 30s grant timeout budget" do
    assert_equal 30, Federation::Client::GRANT_TIMEOUT
    assert_timeout_budget(Federation::Client::GRANT_TIMEOUT) { @client.confirm_grant(7) }
  end

  test "browse applies the 10s content timeout budget" do
    assert_equal 10, Federation::Client::CONTENT_TIMEOUT
    assert_timeout_budget(Federation::Client::CONTENT_TIMEOUT) { @client.browse(7, :songs) }
  end

  test "browse returns parsed JSON list scoped to the library and type" do
    stub_request(:get, "#{BASE_URL}/federation/libraries/7/albums?page=2")
      .with(headers: { "Authorization" => "Bearer #{TOKEN}" })
      .to_return(status: 200, body: [ { id: 1, name: "A" } ].to_json)

    result = @client.browse(7, :albums, { page: 2 })
    assert_equal [ { "id" => 1, "name" => "A" } ], result
  end

  test "stream returns the raw response and forwards range headers" do
    stub = stub_request(:get, "#{BASE_URL}/federation/libraries/7/songs/42/stream")
      .with(headers: { "Authorization" => "Bearer #{TOKEN}", "Range" => "bytes=0-1023" })
      .to_return(status: 200, body: "AUDIOBYTES")

    response = @client.stream(7, 42, { "Range" => "bytes=0-1023" })
    assert_requested(stub)
    assert_equal "AUDIOBYTES", response.body
  end

  test "asset includes the variant query parameter when present" do
    stub = stub_request(:get, "#{BASE_URL}/federation/libraries/7/albums/9/asset?variant=large")
      .to_return(status: 200, body: "IMAGEBYTES")

    response = @client.asset(7, :albums, 9, variant: "large")
    assert_requested(stub)
    assert_equal "IMAGEBYTES", response.body
  end

  # --- Error translation -----------------------------------------------------

  test "translates a read timeout into Federation::Client::Timeout" do
    stub_request(:get, "#{BASE_URL}/federation/ping").to_timeout

    assert_raises(Federation::Client::Timeout) { @client.ping }
  end

  test "translates a refused connection into Federation::Client::Unreachable" do
    stub_request(:get, "#{BASE_URL}/federation/ping").to_raise(Errno::ECONNREFUSED)

    assert_raises(Federation::Client::Unreachable) { @client.ping }
  end

  test "translates a DNS/socket failure into Federation::Client::Unreachable" do
    stub_request(:get, "#{BASE_URL}/federation/ping").to_raise(SocketError)

    assert_raises(Federation::Client::Unreachable) { @client.ping }
  end

  test "translates a 403 into Federation::Client::Unauthorized" do
    stub_request(:get, "#{BASE_URL}/federation/libraries/7/songs")
      .to_return(status: 403, body: "forbidden")

    assert_raises(Federation::Client::Unauthorized) { @client.browse(7, :songs) }
  end

  test "translates a 401 into Federation::Client::Unauthorized" do
    stub_request(:post, "#{BASE_URL}/federation/grants/confirm")
      .to_return(status: 401, body: "unauthorized")

    assert_raises(Federation::Client::Unauthorized) { @client.confirm_grant(7) }
  end

  test "translates other non-success statuses into Federation::Client::Error" do
    stub_request(:get, "#{BASE_URL}/federation/ping").to_return(status: 500, body: "boom")

    assert_raises(Federation::Client::Error) { @client.ping }
  end

  test "domain exceptions all descend from Federation::Client::Error" do
    assert_operator Federation::Client::Timeout, :<, Federation::Client::Error
    assert_operator Federation::Client::Unreachable, :<, Federation::Client::Error
    assert_operator Federation::Client::Unauthorized, :<, Federation::Client::Error
  end

  private

  # Verifies the client passes matching open_timeout/read_timeout options equal
  # to the expected budget to the underlying HTTParty call.
  def assert_timeout_budget(expected)
    captured = nil
    fake_response = Struct.new(:code, :body).new(200, "{}")

    HTTParty.stub(:get, ->(_url, options) { captured = options; fake_response }) do
      HTTParty.stub(:post, ->(_url, options) { captured = options; fake_response }) do
        yield
      end
    end

    assert_equal expected, captured[:open_timeout], "open_timeout should equal the budget"
    assert_equal expected, captured[:read_timeout], "read_timeout should equal the budget"
  end
end
