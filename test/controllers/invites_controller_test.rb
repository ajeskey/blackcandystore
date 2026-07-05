# frozen_string_literal: true

require "test_helper"

class InvitesControllerTest < ActionDispatch::IntegrationTest
  setup do
    # default_library is owned by visitor1 (see fixtures), so visitor1 is the
    # Server_Owner for the purposes of these tests and visitor2 is a non-owner.
    @owner = users(:visitor1)
    @non_owner = users(:visitor2)
    @library = libraries(:default_library)
  end

  test "create mints an invite for the library owner (Req 4.1)" do
    assert_difference -> { AccessGrant.count }, 1 do
      post invites_url,
        params: { library_id: @library.id },
        as: :json,
        headers: api_token_header(@owner)
    end

    assert_response :created

    invite_code = @response.parsed_body["invite_code"]
    assert invite_code.present?

    decoded = InviteManager.decode(invite_code)
    assert_equal BlackCandy.config.server_base_url, decoded[:server_base_url]
    assert AccessGrant.last.authenticate_token(decoded[:secret_token])
  end

  test "invite encodes the configured server base URL setting (Req 4.3)" do
    Setting.update(server_base_url: "https://share.example.com")

    post invites_url,
      params: { library_id: @library.id },
      as: :json,
      headers: api_token_header(@owner)

    assert_response :created
    decoded = InviteManager.decode(@response.parsed_body["invite_code"])
    assert_equal "https://share.example.com", decoded[:server_base_url]
  end

  test "create honors an in-range expires_in (Req 4.5)" do
    freeze_time do
      post invites_url,
        params: { library_id: @library.id, expires_in: 1.hour.to_i },
        as: :json,
        headers: api_token_header(@owner)

      assert_response :created
      assert_in_delta (Time.current + 1.hour).to_i, AccessGrant.last.expires_at.to_i, 1
    end
  end

  test "create rejects an out-of-range expires_in without creating a grant (Req 4.8)" do
    assert_no_difference -> { AccessGrant.count } do
      post invites_url,
        params: { library_id: @library.id, expires_in: 10 }, # 10 seconds < 1 minute
        as: :json,
        headers: api_token_header(@owner)
    end

    assert_response :unprocessable_entity
    assert_equal "InvalidExpiration", @response.parsed_body["type"]
  end

  test "create is rejected for a non-owner and creates no grant (Req 4.6)" do
    assert_no_difference -> { AccessGrant.count } do
      post invites_url,
        params: { library_id: @library.id },
        as: :json,
        headers: api_token_header(@non_owner)
    end

    assert_response :forbidden
    assert_equal "Forbidden", @response.parsed_body["type"]
  end

  test "create returns not-found for a non-local library and creates no grant (Req 4.9)" do
    remote_library = Library.create!(name: "Remote Library", kind: "remote")

    assert_no_difference -> { AccessGrant.count } do
      post invites_url,
        params: { library_id: remote_library.id },
        as: :json,
        headers: api_token_header(@owner)
    end

    assert_response :not_found
    assert_equal "LibraryNotFound", @response.parsed_body["type"]
  end

  test "create requires an authenticated user" do
    post invites_url, params: { library_id: @library.id }, as: :json

    assert_response :unauthorized
  end
end
