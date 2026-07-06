# frozen_string_literal: true

require "test_helper"

# Happy-path coverage for the Co_Listen_Session API_Surface (task 8.9): CRUD,
# the activate/deactivate lifecycle, and Share_Link generation, all through the
# client-agnostic JSON representation (Req 7.1, 9.1, 9.4, 10.7, 10.8). A
# Co_Listen_Session exposes a Stream_Endpoint URL regardless of state (Req 9.6).
class CoListenSessionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    # visitor1 owns default_library, so it may share that library (Req 4.7); the
    # admin exercises the Admin authority path.
    @host = users(:visitor1)
    @admin = users(:admin)
    @library = libraries(:default_library)
  end

  def create_session!
    CoListenSession.create!(
      user: @host,
      session_duration_kind: "perpetual",
      shared_library_ids: [ @library.id ]
    )
  end

  # The activate/deactivate lifecycle performs Broadcaster I/O (task 9.3). In the
  # test environment no Broadcaster runs, so inject the in-memory FakeBroadcaster
  # via the same `Broadcaster.stub(:client, ...)` seam the Stream_Endpoint tests
  # use, letting the lifecycle's default `Broadcaster.client` return the fake so
  # the happy-path activate/deactivate transitions succeed.
  def with_broadcaster(fake = FakeBroadcaster.new)
    Broadcaster.stub(:client, fake) { yield }
  end

  test "create builds a session owned by the host (Req 7.1)" do
    assert_difference -> { CoListenSession.count }, 1 do
      post co_listen_sessions_url,
        params: { co_listen_session: { session_duration_kind: "perpetual", listener_limit: 50, shared_library_ids: [ @library.id ] } },
        as: :json,
        headers: api_token_header(@host)
    end

    assert_response :created
    body = @response.parsed_body
    assert_equal @host.id, body["user_id"]
    assert_equal "active", body["state"]
    assert_equal 50, body["listener_limit"]
    assert_equal [ @library.id ], body["shared_library_ids"]
    # Stream_Endpoint URL exposed regardless of state (Req 9.6).
    assert body["stream_endpoint_url"].present?
  end

  test "index lists the host's sessions (Req 9.1)" do
    session = create_session!

    get co_listen_sessions_url, as: :json, headers: api_token_header(@host)

    assert_response :ok
    assert_includes @response.parsed_body.map { |s| s["id"] }, session.id
  end

  test "show returns the session's client-agnostic state (Req 9.4)" do
    session = create_session!

    get co_listen_session_url(session), as: :json, headers: api_token_header(@host)

    assert_response :ok
    assert_equal session.id, @response.parsed_body["id"]
    assert_includes [ true, false ], @response.parsed_body["audio_available"]
  end

  test "update changes the session configuration (Req 7.7)" do
    session = create_session!

    patch co_listen_session_url(session),
      params: { co_listen_session: { max_guests: 10 } },
      as: :json,
      headers: api_token_header(@host)

    assert_response :ok
    assert_equal 10, @response.parsed_body["max_guests"]
    assert_equal 10, session.reload.max_guests
  end

  test "destroy removes the session (Req 10.8)" do
    session = create_session!

    assert_difference -> { CoListenSession.count }, -1 do
      with_broadcaster do
        delete co_listen_session_url(session), as: :json, headers: api_token_header(@host)
      end
    end

    assert_response :no_content
  end

  test "activate transitions an ended session to active (Req 10.7)" do
    session = create_session!
    session.update!(state: :ended)

    with_broadcaster do
      post activate_co_listen_session_url(session), as: :json, headers: api_token_header(@host)
    end

    assert_response :ok
    assert_equal "active", @response.parsed_body["state"]
    assert session.reload.active?
  end

  test "deactivate transitions an active session to ended (Req 10.8)" do
    session = create_session!

    with_broadcaster do
      post deactivate_co_listen_session_url(session), as: :json, headers: api_token_header(@host)
    end

    assert_response :ok
    assert_equal "ended", @response.parsed_body["state"]
    assert session.reload.ended?
  end

  test "generate_share_link mints an AccessGrant-backed link per shared library (Req 4.2, 8.1)" do
    session = create_session!

    assert_difference -> { ShareLink.count }, 1 do
      post generate_share_link_co_listen_session_url(session), as: :json, headers: api_token_header(@host)
    end

    assert_response :created
    link = @response.parsed_body.first
    assert_equal @library.id, link["library_id"]
    # The plaintext token is returned exactly once so the host can share it.
    assert link["token"].present?
  end
end
