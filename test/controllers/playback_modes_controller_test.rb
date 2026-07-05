# frozen_string_literal: true

require "test_helper"

# Endpoint tests for selecting a Playback_Mode from either player (Req 16.2,
# 16.3, 16.4; Req 18.1). Mirrors the SourcePreferencesController test.
class PlaybackModesControllerTest < ActionDispatch::IntegrationTest
  test "should require login" do
    get playback_mode_url, as: :json
    assert_response :unauthorized
  end

  test "should show the current user's playback mode with audio source" do
    user = users(:admin)
    login user

    get playback_mode_url, as: :json

    assert_response :success
    assert_equal "client_cast", response.parsed_body["playback_mode"]
    assert_equal "client", response.parsed_body["audio_source"]
    assert_equal "cast_session", response.parsed_body["managed_by"]
  end

  test "should record a supported playback mode (Req 16.2, 16.3)" do
    user = users(:admin)
    assert_equal "client_cast", user.playback_mode

    login user
    patch playback_mode_url, params: { playback_mode: "server_playback" }, as: :json

    assert_response :success
    assert_equal "server_playback", user.reload.playback_mode
    assert_equal "server", response.parsed_body["audio_source"]
    assert_equal "playback_session", response.parsed_body["managed_by"]
  end

  test "should reject an unsupported value and leave the existing mode unchanged (Req 16.4)" do
    user = users(:admin)
    user.update!(playback_mode: "server_playback")

    login user
    patch playback_mode_url, params: { playback_mode: "bogus" }, as: :json

    assert_response :unprocessable_entity
    assert_equal "RecordInvalid", response.parsed_body["type"]
    assert_equal "server_playback", user.reload.playback_mode
  end

  test "selecting a mode tears down the other mode's active session (Req 18.1; Property 21)" do
    user = users(:admin)
    user.update!(playback_mode: "client_cast")
    cast = CastSession.create!(user: user, target_output_device_id: 7, state: "playing")

    login user
    patch playback_mode_url, params: { playback_mode: "server_playback" }, as: :json

    assert_response :success
    assert_equal "stopped", cast.reload.state
  end
end
