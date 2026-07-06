# frozen_string_literal: true

require "test_helper"

# Happy-path coverage for the Party_Session API_Surface (task 8.9): CRUD,
# Share_Link generation, and host-only Output_Device selection, through the
# client-agnostic JSON representation (Req 4.1, 4.2, 6.2, 9.1, 9.4). A
# Party_Session deliberately exposes NO Stream_Endpoint (Req 9.7).
class PartySessionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    # visitor1 owns default_library, so it may share that library (Req 4.7).
    @host = users(:visitor1)
    @library = libraries(:default_library)
  end

  def create_session!
    PartySession.create!(
      user: @host,
      session_duration_kind: "perpetual",
      shared_library_ids: [ @library.id ]
    )
  end

  test "create builds a session owned by the host with no stream endpoint (Req 4.1, 9.7)" do
    assert_difference -> { PartySession.count }, 1 do
      post party_sessions_url,
        params: { party_session: { session_duration_kind: "days", session_duration_value: 2, shared_library_ids: [ @library.id ] } },
        as: :json,
        headers: api_token_header(@host)
    end

    assert_response :created
    body = @response.parsed_body
    assert_equal @host.id, body["user_id"]
    assert_equal "active", body["state"]
    assert_equal "days", body["session_duration_kind"]
    # No Stream_Endpoint is exposed for a Party_Session (Req 9.7).
    assert_not body.key?("stream_endpoint_url")
  end

  test "index lists the host's party sessions (Req 9.1)" do
    session = create_session!

    get party_sessions_url, as: :json, headers: api_token_header(@host)

    assert_response :ok
    assert_includes @response.parsed_body.map { |s| s["id"] }, session.id
  end

  test "show returns the session representation without a stream endpoint (Req 9.4, 9.7)" do
    session = create_session!

    get party_session_url(session), as: :json, headers: api_token_header(@host)

    assert_response :ok
    assert_equal session.id, @response.parsed_body["id"]
    assert_not @response.parsed_body.key?("stream_endpoint_url")
  end

  test "update changes the party configuration (Req 4.1)" do
    session = create_session!

    patch party_session_url(session),
      params: { party_session: { duplicate_policy: "allow", max_guests: 8 } },
      as: :json,
      headers: api_token_header(@host)

    assert_response :ok
    assert_equal "allow", @response.parsed_body["duplicate_policy"]
    assert_equal 8, session.reload.max_guests
  end

  test "destroy removes the party session" do
    session = create_session!

    assert_difference -> { PartySession.count }, -1 do
      delete party_session_url(session), as: :json, headers: api_token_header(@host)
    end

    assert_response :no_content
  end

  test "generate_share_link mints an AccessGrant-backed link per shared library (Req 4.2)" do
    session = create_session!

    assert_difference -> { ShareLink.count }, 1 do
      post generate_share_link_party_session_url(session), as: :json, headers: api_token_header(@host)
    end

    assert_response :created
    assert @response.parsed_body.first["token"].present?
  end

  test "revoke terminally revokes the session's share links (Req 4.6)" do
    session = create_session!
    ShareLinkService.generate(session)

    post revoke_party_session_url(session), as: :json, headers: api_token_header(@host)

    assert_response :ok
    grant_ids = session.share_links.pluck(:access_grant_id)
    assert AccessGrant.where(id: grant_ids).all?(&:revoked?)
  end

  test "select_output_devices is accepted for the host (Req 6.2)" do
    session = create_session!

    post select_output_devices_party_session_url(session), as: :json, headers: api_token_header(@host)

    assert_response :ok
    assert_equal session.id, @response.parsed_body["id"]
  end
end
