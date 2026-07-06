# frozen_string_literal: true

require "test_helper"

# Task 9.6 — StreamEndpointController connect-time integration tests.
#
# StreamEndpointController is the single authenticated public surface for a
# Shared_Stream (Req 3.1-3.3). It admits a connect in the design's join order —
# not-broadcasting (503) → auth failure (401) → at-capacity (503) → reverse-proxy
# the Broadcaster fan-out — and this test pins down that ordering and the four
# outcomes Requirements 3.5, 3.6, 3.7, and 11.7 require, from an actual HTTP
# request against the `.mp3` Stream_Endpoint.
#
# The out-of-process Broadcaster is replaced by an in-memory fake injected via
# `Broadcaster.client` (mirroring the fake-broadcaster wiring from task 9.3):
# its `status` reports a controlled listener count for the Listener_Limit
# decision, and its `listen` yields representative MP3 bytes so the public
# bypass path can be observed serving `audio/mpeg` without any real service.
class StreamEndpointTest < ActionDispatch::IntegrationTest
  # An in-memory stand-in for the Broadcaster fan-out/control client. Unlike the
  # shared FakeBroadcaster (control-plane only), this one also implements the
  # data-plane `listen` the Stream_Endpoint reverse-proxies, and lets a test
  # dial in the live listener count that drives the Listener_Limit decision
  # (Req 11.7). It records each `listen` so a test can assert that a *refused*
  # connect never opened a fan-out — i.e. existing Listeners are left untouched.
  class FakeStreamBroadcaster
    # Representative continuous-MP3 bytes: an ID3 tag header followed by an MP3
    # frame sync and some payload. Enough for the client to receive `audio/mpeg`.
    AUDIO_FRAGMENTS = [ "ID3\x04\x00".b, "\xFF\xFB\x90\x64".b, "co-listen-audio-bytes".b ].freeze

    attr_reader :listen_calls, :status_calls

    def initialize(listeners: 0, fragments: AUDIO_FRAGMENTS)
      @listeners = listeners
      @fragments = fragments
      @listen_calls = []
      @status_calls = []
    end

    # Control-plane status: the current listener count feeds the connect-time
    # Listener_Limit admission decision (Req 11.7).
    def status(broadcast_id)
      @status_calls << broadcast_id
      { "broadcast_id" => broadcast_id, "position" => 0, "listeners" => @listeners, "uptime" => 0 }
    end

    # Data-plane fan-out: yield the representative MP3 bytes as the current
    # encode position, exactly as the loopback listen endpoint would (Req 3.2).
    def listen(broadcast_id, &block)
      @listen_calls << broadcast_id
      @fragments.each { |fragment| block.call(fragment) }
    end
  end

  setup do
    # visitor1 owns default_library, so an artist-criterion station selects at
    # least one authorized Song and passes validation (Req 1.4). outsider shares
    # no library with visitor1, exercising the unauthorized-account path.
    @owner = users(:visitor1)
    @artist = artists(:artist1)
    @library = libraries(:default_library)
  end

  def create_radio_station!(visibility: :authenticated, state: :stopped, listener_limit: nil)
    station = RadioStation.create!(
      user: @owner,
      name: "Endpoint Station #{SecureRandom.hex(4)}",
      stream_visibility: visibility,
      listener_limit: listener_limit,
      station_source_criteria: [ StationSourceCriterion.new(criterion_type: "artist", artist_id: @artist.id) ]
    )
    station.update!(state: state)
    station
  end

  def create_co_listen_session!(state: :active, listener_limit: nil)
    session = CoListenSession.create!(
      user: @owner,
      session_duration_kind: "perpetual",
      listener_limit: listener_limit,
      shared_library_ids: [ @library.id ]
    )
    session.update!(state: state)
    session
  end

  def with_broadcaster(fake)
    Broadcaster.stub(:client, fake) { yield }
  end

  # --- Req 3.6: a not-started station is not broadcasting → 503 --------------

  test "a stopped radio station's stream endpoint reports not-broadcasting with 503 (Req 3.6)" do
    station = create_radio_station!(visibility: :public, state: :stopped)

    with_broadcaster(FakeStreamBroadcaster.new) do
      get stream_radio_station_url(station, format: :mp3)
    end

    assert_response :service_unavailable
    assert_equal "NotBroadcasting", @response.parsed_body["type"]
    assert_no_match(%r{audio/}, @response.media_type.to_s)
  end

  test "an ended co-listen session's stream endpoint reports not-broadcasting with 503 (Req 3.6)" do
    session = create_co_listen_session!(state: :ended)

    with_broadcaster(FakeStreamBroadcaster.new) do
      get stream_co_listen_session_url(session, format: :mp3)
    end

    assert_response :service_unavailable
    assert_equal "NotBroadcasting", @response.parsed_body["type"]
  end

  # Not-broadcasting takes precedence over an auth failure: a stopped
  # `authenticated` station with no credentials still reports 503, not 401,
  # matching the design's join order (verify_broadcasting is prepended).
  test "not-broadcasting is checked before authentication (Req 3.6 precedence)" do
    station = create_radio_station!(visibility: :authenticated, state: :stopped)

    with_broadcaster(FakeStreamBroadcaster.new) do
      get stream_radio_station_url(station, format: :mp3)
    end

    assert_response :service_unavailable
    assert_equal "NotBroadcasting", @response.parsed_body["type"]
  end

  # --- Req 3.5: authenticated station, no token and no account → 401 ---------

  test "a started authenticated station rejects a connect with no token and no account (Req 3.5)" do
    station = create_radio_station!(visibility: :authenticated, state: :started)

    with_broadcaster(FakeStreamBroadcaster.new) do
      get stream_radio_station_url(station, format: :mp3)
    end

    assert_response :unauthorized
    assert_no_match(%r{audio/}, @response.media_type.to_s)
  end

  test "an invalid stream token on an authenticated station is still rejected with 401 (Req 3.5)" do
    station = create_radio_station!(visibility: :authenticated, state: :started)
    StreamTokenService.issue_radio_token(station)

    with_broadcaster(FakeStreamBroadcaster.new) do
      get stream_radio_station_url(station, format: :mp3, token: "not-the-real-token")
    end

    assert_response :unauthorized
  end

  # --- Req 3.7 / 11.2: public station serves audio without credentials -------

  test "a started public station serves audio/mpeg to any client with no credentials (Req 3.7)" do
    station = create_radio_station!(visibility: :public, state: :started)
    fake = FakeStreamBroadcaster.new(listeners: 0)

    with_broadcaster(fake) do
      get stream_radio_station_url(station, format: :mp3)
    end

    assert_response :success
    assert_equal "audio/mpeg", @response.get_header("Content-Type")
    assert_equal "radio_station:#{station.id}", fake.listen_calls.last
    # The representative MP3 bytes from the Broadcaster fan-out reached the client.
    assert_equal FakeStreamBroadcaster::AUDIO_FRAGMENTS.join, @response.body
  end

  # Req 11.3/11.4 companion to the 401 case: a valid Stream_Token in the URL
  # authorizes the same authenticated station and audio flows.
  test "a valid stream token authorizes a started authenticated station (Req 3.5 / 11.3)" do
    station = create_radio_station!(visibility: :authenticated, state: :started)
    token = StreamTokenService.issue_radio_token(station).token

    with_broadcaster(FakeStreamBroadcaster.new) do
      get stream_radio_station_url(station, format: :mp3, token: token)
    end

    assert_response :success
    assert_equal "audio/mpeg", @response.get_header("Content-Type")
  end

  # --- Req 11.7: Listener_Limit capacity without disrupting existing ---------

  test "a connect at the listener limit is refused with a capacity 503 and no fan-out is opened (Req 11.7)" do
    # A public station capped at 2 concurrent Listeners, with the Broadcaster
    # already reporting 2 live Listeners — the stream is at capacity.
    station = create_radio_station!(visibility: :public, state: :started, listener_limit: 2)
    fake = FakeStreamBroadcaster.new(listeners: 2)

    with_broadcaster(fake) do
      get stream_radio_station_url(station, format: :mp3)
    end

    assert_response :service_unavailable
    assert_equal "AtCapacity", @response.parsed_body["type"]
    assert_no_match(%r{audio/}, @response.media_type.to_s)
    # The refused connect must not open a fan-out — the existing Listeners are
    # left untouched (Req 11.7: "SHALL NOT disrupt existing Listeners").
    assert_empty fake.listen_calls, "a refused at-capacity connect must not open a Broadcaster fan-out"
  end

  test "a connect above the listener limit is refused with a capacity 503 (Req 11.7)" do
    station = create_radio_station!(visibility: :public, state: :started, listener_limit: 2)
    fake = FakeStreamBroadcaster.new(listeners: 5)

    with_broadcaster(fake) do
      get stream_radio_station_url(station, format: :mp3)
    end

    assert_response :service_unavailable
    assert_equal "AtCapacity", @response.parsed_body["type"]
    assert_empty fake.listen_calls
  end

  test "a connect below the listener limit is admitted and served audio (Req 11.7)" do
    station = create_radio_station!(visibility: :public, state: :started, listener_limit: 2)
    fake = FakeStreamBroadcaster.new(listeners: 1)

    with_broadcaster(fake) do
      get stream_radio_station_url(station, format: :mp3)
    end

    assert_response :success
    assert_equal "audio/mpeg", @response.get_header("Content-Type")
    assert_equal FakeStreamBroadcaster::AUDIO_FRAGMENTS.join, @response.body
    assert_equal "radio_station:#{station.id}", fake.listen_calls.last
  end
end
