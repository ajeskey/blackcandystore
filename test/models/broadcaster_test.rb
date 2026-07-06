# frozen_string_literal: true

require "test_helper"

# Unit tests for the Rails↔Broadcaster control client (task 9.2). They exercise
# the loopback HTTP JSON contract and, crucially, the transport-error → domain
# error (`Unavailable`) translation that mirrors PlaybackSidecar::Client. The
# continuous encode + byte fan-out live in the out-of-process Broadcaster and
# are covered by integration/smoke tests (task 9.5), never here.
class BroadcasterTest < ActiveSupport::TestCase
  # A minimal in-memory HTTP transport stand-in so the control client can be
  # exercised without any real sockets or webmock. It records the last request
  # and returns a canned response, mirroring the HTTParty surface the client
  # uses (`post`/`delete`/`get` returning something with `#code` and `#body`).
  class FakeHttp
    Response = Struct.new(:code, :body)

    attr_reader :calls

    def initialize(status: 200, body: "{}")
      @status = status
      @body = body
      @calls = []
    end

    def post(url, options)
      record(:post, url, options)
    end

    def delete(url, options)
      record(:delete, url, options)
    end

    def get(url, options)
      record(:get, url, options)
    end

    private

    def record(verb, url, options)
      @calls << { verb: verb, url: url, options: options }
      Response.new(@status, @body)
    end
  end

  # An HTTP transport that always fails to reach the Broadcaster.
  class UnreachableHttp
    def post(*) = raise(Errno::ECONNREFUSED)
    def delete(*) = raise(Errno::ECONNREFUSED)
    def get(*) = raise(Errno::ECONNREFUSED)
  end

  BASE_URL = "http://127.0.0.1:9340"

  test "start_broadcast POSTs to /broadcasts and returns the parsed handle" do
    http = FakeHttp.new(status: 201, body: { handle: "stream-1" }.to_json)
    client = Broadcaster::Client.new(base_url: BASE_URL, http: http)

    result = client.start_broadcast(broadcast_id: "radio_station:42", kind: "radio")

    assert_equal "stream-1", result["handle"]
    call = http.calls.sole
    assert_equal :post, call[:verb]
    assert_equal "#{BASE_URL}/broadcasts", call[:url]
    body = JSON.parse(call[:options][:body])
    assert_equal "radio_station:42", body["broadcast_id"]
    assert_equal "radio", body["kind"]
  end

  test "stop_broadcast DELETEs /broadcasts/:id" do
    http = FakeHttp.new(status: 200)
    client = Broadcaster::Client.new(base_url: BASE_URL, http: http)

    client.stop_broadcast("radio_station:42")

    call = http.calls.sole
    assert_equal :delete, call[:verb]
    assert_equal "#{BASE_URL}/broadcasts/radio_station:42", call[:url]
  end

  test "next_source POSTs the resolved source to /broadcasts/:id/next" do
    http = FakeHttp.new(status: 200)
    client = Broadcaster::Client.new(base_url: BASE_URL, http: http)

    client.next_source("co_listen_session:7", source: { song_path: "/stream/1", token: "abc" })

    call = http.calls.sole
    assert_equal :post, call[:verb]
    assert_equal "#{BASE_URL}/broadcasts/co_listen_session:7/next", call[:url]
    body = JSON.parse(call[:options][:body])
    assert_equal "/stream/1", body.dig("source", "song_path")
  end

  test "status GETs /broadcasts/:id/status and returns the parsed document" do
    http = FakeHttp.new(status: 200, body: { position: 12, listeners: 3, uptime: 99 }.to_json)
    client = Broadcaster::Client.new(base_url: BASE_URL, http: http)

    result = client.status("radio_station:42")

    call = http.calls.sole
    assert_equal :get, call[:verb]
    assert_equal "#{BASE_URL}/broadcasts/radio_station:42/status", call[:url]
    assert_equal 12, result["position"]
    assert_equal 3, result["listeners"]
  end

  test "sends short loopback timeouts on every control call" do
    http = FakeHttp.new
    client = Broadcaster::Client.new(base_url: BASE_URL, http: http)

    client.status("radio_station:42")

    options = http.calls.sole[:options]
    assert_equal Broadcaster::CONTROL_TIMEOUT, options[:open_timeout]
    assert_equal Broadcaster::CONTROL_TIMEOUT, options[:read_timeout]
  end

  test "translates a non-success response into Unavailable" do
    http = FakeHttp.new(status: 503)
    client = Broadcaster::Client.new(base_url: BASE_URL, http: http)

    assert_raises(Broadcaster::Unavailable) { client.status("radio_station:42") }
  end

  test "translates a refused connection into Unavailable" do
    client = Broadcaster::Client.new(base_url: BASE_URL, http: UnreachableHttp.new)

    assert_raises(Broadcaster::Unavailable) do
      client.start_broadcast(broadcast_id: "radio_station:42")
    end
  end

  test "translates a timeout into Unavailable" do
    timing_out = Object.new
    def timing_out.get(*) = raise(Net::OpenTimeout)
    client = Broadcaster::Client.new(base_url: BASE_URL, http: timing_out)

    assert_raises(Broadcaster::Unavailable) { client.status("radio_station:42") }
  end

  test "tolerates an empty or unparseable success body" do
    client = Broadcaster::Client.new(base_url: BASE_URL, http: FakeHttp.new(status: 200, body: ""))
    assert_equal({}, client.stop_broadcast("radio_station:42"))

    garbage = Broadcaster::Client.new(base_url: BASE_URL, http: FakeHttp.new(status: 200, body: "not json"))
    assert_equal({}, garbage.status("radio_station:42"))
  end

  test "broadcaster_url falls back to the loopback default when unset" do
    with_env(Broadcaster::BROADCASTER_URL_ENV => nil) do
      assert_equal Broadcaster::DEFAULT_BROADCASTER_URL, Broadcaster.broadcaster_url
    end
  end

  test "broadcaster_url reads the configured base URL from ENV" do
    with_env(Broadcaster::BROADCASTER_URL_ENV => "http://127.0.0.1:9999") do
      assert_equal "http://127.0.0.1:9999", Broadcaster.broadcaster_url
    end
  end
end
