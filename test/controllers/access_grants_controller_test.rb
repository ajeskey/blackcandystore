# frozen_string_literal: true

require "test_helper"

class AccessGrantsControllerTest < ActionDispatch::IntegrationTest
  setup do
    # default_library is owned by visitor1; visitor2 is a non-owner.
    @owner = users(:visitor1)
    @non_owner = users(:visitor2)
    @library = libraries(:default_library)
  end

  # --- index (Req 7.1, 7.5) --------------------------------------------------

  test "index lists a library's grants with status and expiration for its owner (Req 7.1)" do
    grant = create_local_grant(token: "listed-grant")

    get library_access_grants_url(@library),
      as: :json,
      headers: api_token_header(@owner)

    assert_response :success

    listed = @response.parsed_body["access_grants"]
    entry = listed.find { |g| g["id"] == grant.id }

    assert_not_nil entry
    assert_equal "active", entry["status"]
    assert entry.key?("expires_at")
    assert entry.key?("redeemed_at")
  end

  test "index returns an empty list when the library has no grants (Req 7.1)" do
    get library_access_grants_url(@library),
      as: :json,
      headers: api_token_header(@owner)

    assert_response :success
    assert_equal [], @response.parsed_body["access_grants"]
  end

  test "index is rejected for a non-owner (Req 7.5)" do
    create_local_grant(token: "hidden-grant")

    get library_access_grants_url(@library),
      as: :json,
      headers: api_token_header(@non_owner)

    assert_response :forbidden
    assert_equal "Forbidden", @response.parsed_body["type"]
  end

  # Authorization is ownership-based, not privilege-based: an admin who does not
  # own the Library is still a non-owner and must be rejected (Req 7.5).
  test "index is rejected for an admin who does not own the library (Req 7.5)" do
    create_local_grant(token: "admin-hidden-grant")

    get library_access_grants_url(@library),
      as: :json,
      headers: api_token_header(users(:admin))

    assert_response :forbidden
    assert_equal "Forbidden", @response.parsed_body["type"]
  end

  # --- destroy (Req 7.2, 7.5, 7.6, 7.8) --------------------------------------

  test "destroy revokes a grant and confirms the revoked status for its owner (Req 7.2)" do
    grant = create_local_grant(token: "revoke-me")

    delete access_grant_url(grant),
      as: :json,
      headers: api_token_header(@owner)

    assert_response :success
    assert_equal "revoked", @response.parsed_body["status"]
    assert grant.reload.revoked?
  end

  test "destroy leaves every other grant for the library unchanged (Req 7.6)" do
    target = create_local_grant(token: "target")
    other = create_local_grant(token: "other")

    delete access_grant_url(target),
      as: :json,
      headers: api_token_header(@owner)

    assert_response :success
    assert other.reload.active?
  end

  test "destroy is rejected for a non-owner and leaves the grant unchanged (Req 7.5)" do
    grant = create_local_grant(token: "protected")

    delete access_grant_url(grant),
      as: :json,
      headers: api_token_header(@non_owner)

    assert_response :forbidden
    assert_equal "Forbidden", @response.parsed_body["type"]
    assert grant.reload.active?
  end

  # An admin who does not own the grant's Library is rejected too, and the grant
  # stays active — revocation depends on ownership, not admin privilege (Req 7.5).
  test "destroy is rejected for an admin who does not own the library and leaves the grant unchanged (Req 7.5)" do
    grant = create_local_grant(token: "admin-protected")

    delete access_grant_url(grant),
      as: :json,
      headers: api_token_header(users(:admin))

    assert_response :forbidden
    assert_equal "Forbidden", @response.parsed_body["type"]
    assert grant.reload.active?
  end

  test "destroy returns not-found for a missing grant (Req 7.8)" do
    delete access_grant_url(id: 999_999),
      as: :json,
      headers: api_token_header(@owner)

    assert_response :not_found
    assert_equal "GrantNotFound", @response.parsed_body["type"]
  end

  private

  def create_local_grant(token:, status: :active, expires_at: 7.days.from_now)
    grant = AccessGrant.new(library: @library, status: status, expires_at: expires_at)
    grant.token = token
    grant.save!
    grant
  end
end
