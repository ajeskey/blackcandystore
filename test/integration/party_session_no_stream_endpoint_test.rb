# frozen_string_literal: true

require "test_helper"

# Feature: radio-party-colisten, Property 29: Party sessions never expose a stream endpoint
#
# Property 29 (design.md): *For any* session, a Stream_Endpoint is exposed iff it
# is a Radio_Station or a Co_Listen_Session; a Party_Session never exposes a
# Stream_Endpoint (Req 9.7).
#
# A Party_Session plays to host-selected Output_Devices rather than to
# per-Listener streams, so — unlike a Radio_Station or a Co_Listen_Session, which
# each define a member `stream` route and carry a `stream_endpoint_url` in their
# JSON representation — a Party_Session defines NO stream route and its JSON
# carries NO stream endpoint. This integration test pins that contrast down from
# three angles: the routing table, an actual HTTP request, and the JSON body.
class PartySessionNoStreamEndpointTest < ActionDispatch::IntegrationTest
  setup do
    # visitor1 owns default_library, so it may build stations/sessions scoped to
    # that library (Req 4.7). admin is unused here but kept consistent with the
    # sibling controller tests' authority conventions.
    @host = users(:visitor1)
    @library = libraries(:default_library)
    @artist = artists(:artist1)
  end

  def create_party_session!
    PartySession.create!(
      user: @host,
      session_duration_kind: "perpetual",
      shared_library_ids: [ @library.id ]
    )
  end

  def create_co_listen_session!
    CoListenSession.create!(
      user: @host,
      session_duration_kind: "perpetual",
      shared_library_ids: [ @library.id ]
    )
  end

  def create_radio_station!
    RadioStation.create!(
      user: @host,
      name: "Contrast Station",
      station_source_criteria: [ StationSourceCriterion.new(criterion_type: "artist", artist_id: @artist.id) ]
    )
  end

  # A party stream request must never yield audio: it either fails to route
  # (RoutingError raised through the stack) or is rendered as a not-found. Any
  # audio content-type or 2xx would mean a Stream_Endpoint was exposed (Req 9.7).
  def assert_no_stream_served
    yield
    assert_response :not_found, "a party session stream path must not serve a successful response (Req 9.7)"
    assert_no_match(%r{audio/}, @response.media_type.to_s)
  rescue ActionController::RoutingError
    # No route matched — this equally satisfies "no Stream_Endpoint exposed".
    assert true
  end

  # --- Routing table: only Radio_Station and Co_Listen_Session name a stream route.

  test "a party session has no named stream route, while radio stations and co-listen sessions do (Req 9.7)" do
    helpers = Rails.application.routes.url_helpers

    # Contrast: the two stream-bearing session kinds DO expose a stream route.
    assert helpers.respond_to?(:stream_radio_station_path),
      "expected radio stations to expose a stream endpoint route"
    assert helpers.respond_to?(:stream_co_listen_session_path),
      "expected co-listen sessions to expose a stream endpoint route"

    # A Party_Session names no stream route at all.
    assert_not helpers.respond_to?(:stream_party_session_path),
      "a party session must not expose a stream endpoint route (Req 9.7)"
  end

  # --- Route recognition: a party stream path resolves to no route at all.

  test "no route matches a party session stream path (Req 9.7)" do
    routes = Rails.application.routes

    # A would-be party stream path matches NO route — the routing table has no
    # entry for it, so recognition fails with an explicit "No route matches".
    party_error = assert_raises(ActionController::RoutingError) do
      routes.recognize_path("/party_sessions/1/stream", method: :get)
    end
    assert_match(/No route matches/, party_error.message)

    # Contrast: the stream-bearing kinds DO have a matching route. Recognition
    # resolves the route (it may reference a controller that is wired up in a
    # later phase), so it never fails with "No route matches".
    [ "/radio_stations/1/stream", "/co_listen_sessions/1/stream" ].each do |path|
      begin
        routes.recognize_path(path, method: :get)
      rescue ActionController::RoutingError => e
        refute_match(/No route matches/, e.message,
          "expected a route to match #{path}, but none did")
      end
    end
  end

  # --- Live request: attempting to tune into a party session is not served.

  test "attempting to GET a party session stream endpoint is not served (Req 9.7)" do
    session = create_party_session!

    # There is no Stream_Endpoint to serve audio from. The request either fails
    # to route (RoutingError) or is rendered as a not-found — never audio.
    assert_no_stream_served { get "/party_sessions/#{session.id}/stream", headers: api_token_header(@host) }
    assert_no_stream_served { get "/party_sessions/#{session.id}/stream.mp3", headers: api_token_header(@host) }
  end

  # --- JSON representation: no stream_endpoint_url for a party session.

  test "the party session JSON representation carries no stream_endpoint_url (Req 9.7)" do
    session = create_party_session!

    get party_session_url(session), as: :json, headers: api_token_header(@host)

    assert_response :ok
    assert_not @response.parsed_body.key?("stream_endpoint_url"),
      "a party session JSON must not carry a stream endpoint URL (Req 9.7)"
    assert_nil @response.parsed_body["stream_endpoint_url"]
  end

  # --- Contrast: the other two session kinds DO carry a stream_endpoint_url.

  test "a radio station and a co-listen session both expose a stream_endpoint_url in JSON (Req 9.7 contrast)" do
    station = create_radio_station!
    session = create_co_listen_session!

    get radio_station_url(station), as: :json, headers: api_token_header(@host)
    assert_response :ok
    assert @response.parsed_body["stream_endpoint_url"].present?,
      "a radio station JSON must expose a stream endpoint URL"

    get co_listen_session_url(session), as: :json, headers: api_token_header(@host)
    assert_response :ok
    assert @response.parsed_body["stream_endpoint_url"].present?,
      "a co-listen session JSON must expose a stream endpoint URL"
  end
end
