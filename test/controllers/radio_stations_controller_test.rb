# frozen_string_literal: true

require "test_helper"

# Happy-path coverage for the Radio_Station API_Surface (task 8.9): CRUD, the
# start/stop lifecycle, and Stream_Token rotate/revoke, exercised through the
# client-agnostic JSON representation (Req 1.1, 9.4, 10.1, 10.2, 11.5). Every
# request authenticates as a full account through the Bearer path
# (`api_token_header`), mirroring the existing controller-test conventions.
class RadioStationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    # visitor1 owns default_library (see fixtures), so its authorized libraries
    # contain every fixture Song — the criteria below therefore select at least
    # one playable Song (Req 1.4). admin exercises the Admin authority path.
    @owner = users(:visitor1)
    @admin = users(:admin)
    @artist = artists(:artist1)
  end

  def create_station!(name: "Owner Station")
    RadioStation.create!(
      user: @owner,
      name: name,
      station_source_criteria: [ StationSourceCriterion.new(criterion_type: "artist", artist_id: @artist.id) ]
    )
  end

  # The start/stop lifecycle performs Broadcaster I/O (task 9.3). In the test
  # environment no Broadcaster runs, so inject the in-memory FakeBroadcaster via
  # the same `Broadcaster.stub(:client, ...)` seam the Stream_Endpoint tests use,
  # letting the lifecycle's default `Broadcaster.client` return the fake so the
  # happy-path start/stop transitions succeed.
  def with_broadcaster(fake = FakeBroadcaster.new)
    Broadcaster.stub(:client, fake) { yield }
  end

  test "index lists the current user's stations as JSON (Req 9.1, 9.4)" do
    station = create_station!

    get radio_stations_url, as: :json, headers: api_token_header(@owner)

    assert_response :ok
    ids = @response.parsed_body.map { |s| s["id"] }
    assert_includes ids, station.id
  end

  test "create builds a station owned by the current user from artist criteria (Req 1.1, 1.2)" do
    assert_difference -> { RadioStation.count }, 1 do
      post radio_stations_url,
        params: { radio_station: { name: "My Station", criteria: [ { criterion_type: "artist", artist_id: @artist.id } ] } },
        as: :json,
        headers: api_token_header(@owner)
    end

    assert_response :created
    body = @response.parsed_body
    assert_equal "My Station", body["name"]
    assert_equal "stopped", body["state"]
    assert_equal "authenticated", body["stream_visibility"]
    assert_equal @owner.id, body["user_id"]
    assert_equal @owner.id, RadioStation.find(body["id"]).user_id
    # The Stream_Endpoint URL is exposed regardless of state (Req 9.6).
    assert body["stream_endpoint_url"].present?
  end

  test "show returns a single station's client-agnostic representation (Req 9.4)" do
    station = create_station!

    get radio_station_url(station), as: :json, headers: api_token_header(@owner)

    assert_response :ok
    assert_equal station.id, @response.parsed_body["id"]
    assert_equal 1, @response.parsed_body["station_source_criteria"].size
  end

  test "update renames a station (Req 1.1)" do
    station = create_station!

    patch radio_station_url(station),
      params: { radio_station: { name: "Renamed Station" } },
      as: :json,
      headers: api_token_header(@owner)

    assert_response :ok
    assert_equal "Renamed Station", @response.parsed_body["name"]
    assert_equal "Renamed Station", station.reload.name
  end

  test "destroy removes the station configuration (Req 1.7)" do
    station = create_station!

    assert_difference -> { RadioStation.count }, -1 do
      with_broadcaster do
        delete radio_station_url(station), as: :json, headers: api_token_header(@owner)
      end
    end

    assert_response :no_content
    assert_nil RadioStation.find_by(id: station.id)
  end

  test "start transitions the station to started for the owner (Req 10.1)" do
    station = create_station!

    with_broadcaster do
      post start_radio_station_url(station), as: :json, headers: api_token_header(@owner)
    end

    assert_response :ok
    assert_equal "started", @response.parsed_body["state"]
    assert station.reload.started?
  end

  test "an admin may start a station they do not own (Req 10.1)" do
    station = create_station!

    with_broadcaster do
      post start_radio_station_url(station), as: :json, headers: api_token_header(@admin)
    end

    assert_response :ok
    assert station.reload.started?
  end

  test "stop transitions a started station back to stopped (Req 10.2)" do
    station = create_station!
    station.update!(state: :started)

    with_broadcaster do
      post stop_radio_station_url(station), as: :json, headers: api_token_header(@owner)
    end

    assert_response :ok
    assert_equal "stopped", @response.parsed_body["state"]
    assert station.reload.stopped?
  end

  test "rotate_stream_token issues a fresh token returned exactly once (Req 11.5)" do
    station = create_station!

    post rotate_stream_token_radio_station_url(station), as: :json, headers: api_token_header(@owner)

    assert_response :ok
    token = @response.parsed_body.dig("stream_token", "token")
    assert token.present?
    # Only the keyed digest is persisted; the plaintext validates against it.
    assert station.reload.stream_token.present?
    assert station.stream_token.authenticate_token(token)
  end

  test "revoke_stream_token terminally revokes the station's token (Req 11.5)" do
    station = create_station!
    StreamTokenService.issue_radio_token(station)

    post revoke_stream_token_radio_station_url(station), as: :json, headers: api_token_header(@owner)

    assert_response :ok
    assert station.reload.stream_token.revoked?
  end
end
