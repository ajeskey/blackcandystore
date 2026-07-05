# frozen_string_literal: true

require "test_helper"

# Browser-facing sharing flow: the owner's sharing page (generate invite + list
# / revoke access grants) and the redeem-a-code form.
class SharingUiTest < ActionDispatch::IntegrationTest
  setup do
    @owner = users(:visitor1)          # owner of default_library
    @library = libraries(:default_library)
    @non_owner = users(:visitor2)
  end

  test "owner can view the sharing page for their library" do
    login(@owner)

    get library_access_grants_path(@library)

    assert_response :success
  end

  test "a non-owner cannot view the sharing page" do
    login(@non_owner)

    get library_access_grants_path(@library)

    assert_response :forbidden
  end

  test "generating an invite via the form redirects and exposes the code once via flash" do
    login(@owner)

    post invites_path,
      params: { library_id: @library.id, expires_in: 7.days.to_i },
      headers: { "HTTP_REFERER" => library_access_grants_url(@library) }

    assert_redirected_to library_access_grants_url(@library)
    assert flash[:invite_code].present?
  end

  test "the redeem-a-code form renders" do
    login(@owner)

    get new_redemption_path

    assert_response :success
  end

  test "revoking an access grant from the UI redirects back" do
    login(@owner)
    grant = AccessGrant.create!(library: @library, token: "ui-revoke-token", expires_at: 7.days.from_now)

    delete access_grant_path(grant),
      headers: { "HTTP_REFERER" => library_access_grants_url(@library) }

    assert_redirected_to library_access_grants_url(@library)
    assert_equal "revoked", grant.reload.status
  end
end
