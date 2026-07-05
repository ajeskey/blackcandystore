# frozen_string_literal: true

require "test_helper"

class UserSettingTest < ActiveSupport::TestCase
  test "should have AVAILABLE_SETTINGS constant" do
    assert_equal [ :theme, :source_preference, :playback_mode ], User::AVAILABLE_SETTINGS
  end

  test "should default source_preference to prefer_own_server" do
    user = users(:visitor1)

    assert_nil user.settings["source_preference"]
    assert_equal "prefer_own_server", user.source_preference
    assert_equal User::DEFAULT_SOURCE_PREFERENCE, user.source_preference
  end

  test "should persist source_preference when set to a supported value" do
    user = users(:visitor1)

    user.source_preference = "prefer_highest_quality"
    user.save

    assert_equal "prefer_highest_quality", user.reload.source_preference
  end

  test "should get default value when setting value did not set" do
    user = users(:visitor1)

    assert_nil user.settings["theme"]
    assert_equal User::DEFAULT_THEME, user.theme
  end

  test "should update settings" do
    user = users(:visitor1)
    assert_equal "auto", user.theme

    user.theme = "light"
    user.save

    assert_equal "light", user.reload.theme
  end

  test "should validte theme options" do
    user = users(:visitor1)
    assert_equal "auto", user.theme

    user.theme = "fake_theme"
    user.save

    assert_not user.valid?
    assert_equal "auto", user.reload.theme
  end

  # Req 11.10: an invalid Source_Preference value is rejected and the existing
  # value is left unchanged.
  test "should reject an invalid source_preference and leave the existing value unchanged" do
    user = users(:visitor1)
    user.update!(source_preference: "prefer_highest_quality")

    user.source_preference = "not_a_preference"

    assert_not user.valid?
    assert_not user.save
    assert_equal "prefer_highest_quality", user.reload.source_preference
  end

  # Req 11.10: both supported values pass validation.
  test "should accept supported source_preference values" do
    user = users(:visitor1)

    User::SOURCE_PREFERENCE_OPTIONS.each do |value|
      user.source_preference = value
      assert user.valid?, "expected #{value} to be a valid source_preference"
    end
  end

  # Req 16.1, 16.2, 16.3: playback_mode defaults to client_cast when unset.
  test "should default playback_mode to client_cast" do
    user = users(:visitor1)

    assert_nil user.settings["playback_mode"]
    assert_equal "client_cast", user.playback_mode
    assert_equal User::DEFAULT_PLAYBACK_MODE, user.playback_mode
  end

  # Req 16.2, 16.3: a supported playback_mode is recorded.
  test "should persist playback_mode when set to a supported value" do
    user = users(:visitor1)

    user.playback_mode = "server_playback"
    user.save

    assert_equal "server_playback", user.reload.playback_mode
  end

  # Req 16.4: an invalid playback_mode value is rejected and the existing mode
  # is left unchanged.
  test "should reject an invalid playback_mode and leave the existing mode unchanged" do
    user = users(:visitor1)
    user.update!(playback_mode: "server_playback")

    user.playback_mode = "not_a_mode"

    assert_not user.valid?
    assert_not user.save
    assert_equal "server_playback", user.reload.playback_mode
  end

  # Req 16.1, 16.4: both supported values pass validation.
  test "should accept supported playback_mode values" do
    user = users(:visitor1)

    User::PLAYBACK_MODE_OPTIONS.each do |value|
      user.playback_mode = value
      assert user.valid?, "expected #{value} to be a valid playback_mode"
    end
  end
end
