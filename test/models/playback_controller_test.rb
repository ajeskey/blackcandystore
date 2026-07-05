# frozen_string_literal: true

require "test_helper"

class PlaybackControllerTest < ActiveSupport::TestCase
  setup do
    @user = users(:admin)
    # A reachability resolver that treats only a known set of ids as reachable,
    # so the state machine can be exercised without Device_Discovery/sidecar.
    @reachable_ids = [ 1, 2, 3 ].to_set
    @reachable = ->(id) { @reachable_ids.include?(id.to_i) }
  end

  def build_controller(**session_attrs)
    session = PlaybackSession.create!(user: @user, **session_attrs)
    PlaybackController.new(session, reachable: @reachable)
  end

  # --- device selection (Req 14.1, 14.13) ---

  test "selecting reachable devices makes them the active targets (Req 14.1)" do
    controller = build_controller
    result = controller.select_devices([ 1, 2 ])

    assert result.ok?
    assert_equal [ 1, 2 ], controller.session.reload.active_output_device_ids
  end

  test "selecting an unreachable device is rejected and leaves devices unchanged (Req 14.13)" do
    controller = build_controller(active_output_device_ids: [ 1 ])
    result = controller.select_devices([ 2, 99 ])

    assert result.rejected?
    assert_equal :device_unreachable, result.error
    assert_equal [ 1 ], controller.session.reload.active_output_device_ids
  end

  test "device selection does not change playback state" do
    controller = build_controller(state: "stopped")
    controller.select_devices([ 1 ])
    assert_equal "stopped", controller.session.reload.state
  end

  # --- play (Req 14.3, 14.14) ---

  test "play with an active device sets current song, position and playing state (Req 14.3)" do
    controller = build_controller(active_output_device_ids: [ 1 ])
    result = controller.play(song_id: 42, position: 10)

    assert result.ok?
    session = controller.session.reload
    assert_equal "playing", session.state
    assert_equal 42, session.current_song_id
    assert_equal 10, session.position
  end

  test "play with no active device is rejected leaving state unchanged (Req 14.14)" do
    controller = build_controller(state: "stopped", active_output_device_ids: [])
    result = controller.play(song_id: 42)

    assert result.rejected?
    assert_equal :no_output_device, result.error
    session = controller.session.reload
    assert_equal "stopped", session.state
    assert_nil session.current_song_id
  end

  test "play without a song to play is rejected" do
    controller = build_controller(active_output_device_ids: [ 1 ])
    result = controller.play(song_id: nil)

    assert result.rejected?
    assert_equal :no_current_song, result.error
    assert_equal "stopped", controller.session.reload.state
  end

  # --- pause + resume (Req 14.4, 14.16) ---

  test "pause on a playing session retains song and position and moves to paused (Req 14.4)" do
    controller = build_controller(
      state: "playing", active_output_device_ids: [ 1 ], current_song_id: 7, position: 55
    )
    result = controller.pause

    assert result.ok?
    session = controller.session.reload
    assert_equal "paused", session.state
    assert_equal 7, session.current_song_id
    assert_equal 55, session.position
  end

  test "pause on a non-playing session leaves the state unchanged (Req 14.15)" do
    controller = build_controller(state: "stopped")
    controller.pause
    assert_equal "stopped", controller.session.reload.state
  end

  test "resume immediately after pause returns to playing with retained song and position (Req 14.16)" do
    controller = build_controller(
      state: "playing", active_output_device_ids: [ 1 ], current_song_id: 7, position: 55
    )
    controller.pause
    assert_equal "paused", controller.session.reload.state

    result = controller.resume

    assert result.ok?
    session = controller.session.reload
    assert_equal "playing", session.state
    assert_equal 7, session.current_song_id
    assert_equal 55, session.position
  end

  test "resume with no active device is rejected leaving state unchanged (Req 14.14)" do
    controller = build_controller(state: "paused", active_output_device_ids: [], current_song_id: 7, position: 55)
    result = controller.resume

    assert result.rejected?
    assert_equal :no_output_device, result.error
    assert_equal "paused", controller.session.reload.state
  end

  test "resume with no current song is rejected" do
    controller = build_controller(state: "paused", active_output_device_ids: [ 1 ], current_song_id: nil)
    result = controller.resume

    assert result.rejected?
    assert_equal :no_current_song, result.error
  end

  # --- stop (Req 14.5) ---

  test "stop clears position and moves to stopped (Req 14.5)" do
    controller = build_controller(
      state: "playing", active_output_device_ids: [ 1 ], current_song_id: 7, position: 55
    )
    result = controller.stop

    assert result.ok?
    session = controller.session.reload
    assert_equal "stopped", session.state
    assert_equal 0, session.position
  end

  # --- volume (Req 14.6) ---

  test "volume within range for the active group is accepted (Req 14.6)" do
    controller = build_controller(active_output_device_ids: [ 1, 2 ])
    assert controller.set_volume(50).ok?
  end

  test "volume for a specific active device is accepted (Req 14.6)" do
    controller = build_controller(active_output_device_ids: [ 1, 2 ])
    assert controller.set_volume(30, device_id: 2).ok?
  end

  test "volume out of range is rejected" do
    controller = build_controller(active_output_device_ids: [ 1 ])
    assert_equal :invalid_volume, controller.set_volume(150).error
    assert_equal :invalid_volume, controller.set_volume(-1).error
  end

  test "volume for a device that is not active is rejected" do
    controller = build_controller(active_output_device_ids: [ 1 ])
    assert_equal :device_not_active, controller.set_volume(20, device_id: 99).error
  end

  # --- device becoming unavailable (Req 14.11, 14.12) ---

  test "losing one of several devices while playing keeps playing on the rest (Req 14.11)" do
    controller = build_controller(state: "playing", active_output_device_ids: [ 1, 2 ], current_song_id: 7)
    result = controller.device_unavailable(1)

    assert result.ok?
    session = controller.session.reload
    assert_equal "playing", session.state
    assert_equal [ 2 ], session.active_output_device_ids
  end

  test "losing the last device while playing stops playback with a reason (Req 14.12)" do
    controller = build_controller(state: "playing", active_output_device_ids: [ 1 ], current_song_id: 7)
    result = controller.device_unavailable(1)

    assert result.ok?
    assert_equal PlaybackController::REASON_NO_DEVICE_AVAILABLE, result.reason
    session = controller.session.reload
    assert_equal "stopped", session.state
    assert_equal [], session.active_output_device_ids
  end

  test "losing the last device while paused does not force a stop reason" do
    controller = build_controller(state: "paused", active_output_device_ids: [ 1 ], current_song_id: 7)
    result = controller.device_unavailable(1)

    assert result.ok?
    assert_nil result.reason
    assert_equal "paused", controller.session.reload.state
    assert_equal [], controller.session.active_output_device_ids
  end

  test "losing a device that is not active is a no-op" do
    controller = build_controller(state: "playing", active_output_device_ids: [ 1, 2 ], current_song_id: 7)
    result = controller.device_unavailable(99)

    assert result.ok?
    assert_equal [ 1, 2 ], controller.session.reload.active_output_device_ids
    assert_equal "playing", controller.session.state
  end

  # --- state invariant (Req 14.15) ---

  test "state is always one of stopped/playing/paused across operations (Req 14.15)" do
    controller = build_controller
    controller.select_devices([ 1 ])
    controller.play(song_id: 7)
    controller.pause
    controller.resume
    controller.device_unavailable(1)

    assert_includes PlaybackSession::STATES, controller.session.reload.state
  end

  # --- for_user + default reachability (Req 14.1, 14.13) ---

  test "for_user finds or creates a single session for the user (Req 14.1)" do
    first = PlaybackController.for_user(@user).session
    second = PlaybackController.for_user(@user).session
    assert_equal first.id, second.id
  end

  test "default reachability treats a device with a reachable_at timestamp as reachable (Req 14.13)" do
    device = OutputDevice.create!(identifier: "dev-1", protocol: "airplay", reachable_at: Time.current)
    stale = OutputDevice.create!(identifier: "dev-2", protocol: "airplay", reachable_at: nil)

    controller = PlaybackController.new(PlaybackSession.create!(user: @user))
    assert controller.select_devices([ device.id ]).ok?
    assert controller.select_devices([ stale.id ]).rejected?
  end
end
