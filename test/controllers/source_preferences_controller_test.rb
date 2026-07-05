# frozen_string_literal: true

require "test_helper"

class SourcePreferencesControllerTest < ActionDispatch::IntegrationTest
  test "should require login" do
    get source_preference_url, as: :json
    assert_response :unauthorized
  end

  test "should show current user source preference" do
    user = users(:admin)
    login user

    get source_preference_url, as: :json

    assert_response :success
    assert_equal "prefer_own_server", response.parsed_body["source_preference"]
  end

  test "should update source preference with a supported value" do
    user = users(:admin)
    assert_equal "prefer_own_server", user.source_preference

    login user
    patch source_preference_url, params: { source_preference: "prefer_highest_quality" }, as: :json

    assert_response :success
    assert_equal "prefer_highest_quality", user.reload.source_preference
    assert_equal "prefer_highest_quality", response.parsed_body["source_preference"]
  end

  test "should reject an unsupported value and leave existing preference unchanged" do
    user = users(:admin)
    user.update!(source_preference: "prefer_highest_quality")

    login user
    patch source_preference_url, params: { source_preference: "bogus" }, as: :json

    assert_response :unprocessable_entity
    assert_equal "RecordInvalid", response.parsed_body["type"]
    assert_equal "prefer_highest_quality", user.reload.source_preference
  end
end
