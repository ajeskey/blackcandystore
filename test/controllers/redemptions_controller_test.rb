# frozen_string_literal: true

require "test_helper"

class RedemptionsControllerTest < ActionDispatch::IntegrationTest
  REMOTE_BASE_URL = "https://remote.example.com"
  REMOTE_CONFIRM_URL = "https://remote.example.com/federation/grants/confirm"

  setup do
    @user = users(:visitor2)
    @library = libraries(:default_library)
  end

  test "create redeems a local invite code and returns the shared library (Req 5.1)" do
    token = "local-redeem-token"
    grant = create_local_grant(token: token)

    post redemptions_url,
      params: { invite_code: local_code(token) },
      as: :json,
      headers: api_token_header(@user)

    assert_response :created
    assert_equal @library.id, @response.parsed_body["library"]["id"]
    assert_equal @library.name, @response.parsed_body["library"]["name"]

    grant.reload
    assert_equal @user.id, grant.redeemer_user_id
    assert grant.redeemed_at.present?
  end

  test "create rejects a malformed invite code without side effects (Req 5.3)" do
    assert_no_difference -> { AccessGrant.where.not(redeemer_user_id: nil).count } do
      post redemptions_url,
        params: { invite_code: "not a valid code !!!" },
        as: :json,
        headers: api_token_header(@user)
    end

    assert_response :unprocessable_entity
    assert_equal "Malformed", @response.parsed_body["type"]
  end

  test "create rejects a first-time redemption of an expired code (Req 5.4)" do
    token = "expired-token"
    create_local_grant(token: token, expires_at: 1.hour.ago)

    post redemptions_url,
      params: { invite_code: local_code(token) },
      as: :json,
      headers: api_token_header(@user)

    assert_response :forbidden
    assert_equal "Expired", @response.parsed_body["type"]
  end

  test "create rejects a revoked grant (Req 5.5)" do
    token = "revoked-token"
    create_local_grant(token: token, status: :revoked)

    post redemptions_url,
      params: { invite_code: local_code(token) },
      as: :json,
      headers: api_token_header(@user)

    assert_response :forbidden
    assert_equal "Revoked", @response.parsed_body["type"]
  end

  test "create confirms a cross-server grant and returns the connection (Req 5.2)" do
    token = "remote-token"
    stub_request(:post, REMOTE_CONFIRM_URL).to_return(
      status: 200,
      body: { library: { id: 42, name: "Shared Library" }, valid: true }.to_json,
      headers: { "Content-Type" => "application/json" }
    )

    assert_difference -> { LibraryConnection.count }, 1 do
      post redemptions_url,
        params: { invite_code: remote_code(token) },
        as: :json,
        headers: api_token_header(@user)
    end

    assert_response :created
    connection = @response.parsed_body["connection"]
    assert_equal REMOTE_BASE_URL, connection["server_base_url"]
    assert_equal 42, connection["remote_library_id"]
  end

  test "create surfaces an unavailable issuing server (Req 5.7)" do
    token = "unreachable-token"
    stub_request(:post, REMOTE_CONFIRM_URL).to_timeout

    assert_no_difference -> { LibraryConnection.count } do
      post redemptions_url,
        params: { invite_code: remote_code(token) },
        as: :json,
        headers: api_token_header(@user)
    end

    assert_response :service_unavailable
    assert_equal "ServerUnavailable", @response.parsed_body["type"]
  end

  test "create requires an authenticated user" do
    post redemptions_url, params: { invite_code: "anything" }, as: :json

    assert_response :unauthorized
  end

  private

  def create_local_grant(token:, status: :active, expires_at: 7.days.from_now)
    grant = AccessGrant.new(library: @library, status: status, expires_at: expires_at)
    grant.token = token
    grant.save!
    grant
  end

  def local_code(token)
    InviteManager.encode(server_base_url: BlackCandy.config.server_base_url, secret_token: token)
  end

  def remote_code(token)
    InviteManager.encode(server_base_url: REMOTE_BASE_URL, secret_token: token)
  end
end
