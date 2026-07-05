# frozen_string_literal: true

require "test_helper"

class CastSessionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:admin)
  end

  test "requires an authenticated user" do
    get cast_session_url, as: :json
    assert_response :unauthorized
  end

  test "create selects a target output device and current song (Req 17.1)" do
    assert_difference -> { CastSession.count }, 1 do
      post cast_session_url,
        params: { target_output_device_id: 7, current_song_id: 42 },
        as: :json,
        headers: api_token_header(@user)
    end

    assert_response :created
    body = @response.parsed_body
    assert_equal "stopped", body["state"]
    assert_equal 7, body["target_output_device_id"]
    assert_equal 42, body["current_song_id"]
  end

  test "create updates the existing session for a user (one-per-user)" do
    CastSession.create!(user: @user, target_output_device_id: 1)

    assert_no_difference -> { CastSession.count } do
      post cast_session_url,
        params: { target_output_device_id: 9 },
        as: :json,
        headers: api_token_header(@user)
    end

    assert_response :created
    assert_equal 9, @response.parsed_body["target_output_device_id"]
  end

  test "play moves the session to playing (Req 17.5)" do
    CastSession.create!(user: @user, target_output_device_id: 7)

    post play_cast_session_url,
      params: { current_song_id: 42 },
      as: :json,
      headers: api_token_header(@user)

    assert_response :success
    assert_equal "playing", @response.parsed_body["state"]
    assert_equal 42, @response.parsed_body["current_song_id"]
  end

  test "play with no target output device is rejected and leaves state unchanged (Property 20)" do
    session = CastSession.create!(user: @user, target_output_device_id: nil, state: "stopped")

    post play_cast_session_url,
      params: { current_song_id: 42 },
      as: :json,
      headers: api_token_header(@user)

    assert_response :unprocessable_entity
    assert_equal "CastTransitionRejected", @response.parsed_body["type"]
    assert_equal "stopped", session.reload.state
    assert_nil session.current_song_id
  end

  test "pause then resume returns to playing retaining song and position (Req 17.16; Property 20)" do
    CastSession.create!(user: @user, target_output_device_id: 7, state: "playing", current_song_id: 42, position: 33)

    post pause_cast_session_url, as: :json, headers: api_token_header(@user)
    assert_response :success
    assert_equal "paused", @response.parsed_body["state"]
    assert_equal 33, @response.parsed_body["position"]

    post resume_cast_session_url, as: :json, headers: api_token_header(@user)
    assert_response :success
    body = @response.parsed_body
    assert_equal "playing", body["state"]
    assert_equal 42, body["current_song_id"]
    assert_equal 33, body["position"]
  end

  test "stop clears the position and moves to stopped (Req 17.7)" do
    CastSession.create!(user: @user, target_output_device_id: 7, state: "playing", current_song_id: 42, position: 33)

    post stop_cast_session_url, as: :json, headers: api_token_header(@user)

    assert_response :success
    body = @response.parsed_body
    assert_equal "stopped", body["state"]
    assert_equal 0, body["position"]
  end

  test "show reports the current cast session state" do
    CastSession.create!(user: @user, target_output_device_id: 7, state: "paused", current_song_id: 42, position: 33)

    get cast_session_url, as: :json, headers: api_token_header(@user)

    assert_response :success
    assert_equal "paused", @response.parsed_body["state"]
  end
end
