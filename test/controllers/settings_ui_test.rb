# frozen_string_literal: true

require "test_helper"

class SettingsUiTest < ActionDispatch::IntegrationTest
  test "settings page renders for a user" do
    login(users(:visitor1))

    get setting_path

    assert_response :success
  end

  test "a user can update their source preference from settings" do
    user = users(:visitor1)
    login(user)

    patch source_preference_path,
      params: { source_preference: "prefer_highest_quality" },
      headers: { "HTTP_REFERER" => setting_url }

    assert_response :redirect
    assert_equal "prefer_highest_quality", user.reload.source_preference
  end

  test "a user can update their playback mode from settings" do
    user = users(:visitor1)
    login(user)

    patch playback_mode_path,
      params: { playback_mode: "server_playback" },
      headers: { "HTTP_REFERER" => setting_url }

    assert_response :redirect
    assert_equal "server_playback", user.reload.playback_mode
  end

  test "an admin can toggle DAAP and RSP from settings" do
    login(users(:admin))

    patch setting_path, params: { setting: { enable_daap: "1", enable_rsp: "1" } }

    assert_redirected_to setting_path
    assert Setting.enable_daap
    assert Setting.enable_rsp
  end
end
