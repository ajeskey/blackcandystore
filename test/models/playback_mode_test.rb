# frozen_string_literal: true

require "test_helper"

# Unit tests for the PlaybackMode coordination layer (Req 16, 18; design
# Property 21). Property 21 itself is exercised across generated inputs by the
# property test in task 26.2; these focused examples pin down the API and the
# mode-exclusivity invariant on representative cases.
class PlaybackModeTest < ActiveSupport::TestCase
  setup do
    @user = users(:admin)
  end

  # --- classification / audio source (Req 16.5, 16.6, 16.7) ----------------

  test "for returns a Cast_Session under client_cast (Req 18.2)" do
    @user.update!(playback_mode: "client_cast")
    session = PlaybackMode.for(@user)

    assert_instance_of CastSession, session
    assert_equal @user, session.user
  end

  test "for returns a Playback_Session under server_playback (Req 18.3)" do
    @user.update!(playback_mode: "server_playback")
    session = PlaybackMode.for(@user)

    assert_instance_of PlaybackSession, session
    assert_equal @user, session.user
  end

  test "manager reports the managing session kind per mode" do
    @user.update!(playback_mode: "client_cast")
    assert_equal :cast_session, PlaybackMode.manager(@user)

    @user.update!(playback_mode: "server_playback")
    assert_equal :playback_session, PlaybackMode.manager(@user)
  end

  test "audio source is the client under client_cast and the server under server_playback (Req 16.6, 16.7)" do
    @user.update!(playback_mode: "client_cast")
    assert_equal "client", PlaybackMode.audio_source(@user)

    @user.update!(playback_mode: "server_playback")
    assert_equal "server", PlaybackMode.audio_source(@user)
  end

  # --- selection (Req 16.2, 16.3, 16.4) ------------------------------------

  test "select records a supported mode and returns its managing session" do
    session = PlaybackMode.select(@user, "server_playback")

    assert_equal "server_playback", @user.reload.playback_mode
    assert_instance_of PlaybackSession, session
  end

  test "select rejects an unsupported mode and leaves the existing mode unchanged (Req 16.4)" do
    @user.update!(playback_mode: "client_cast")

    assert_raises(ActiveRecord::RecordInvalid) { PlaybackMode.select(@user, "bogus") }
    assert_equal "client_cast", @user.reload.playback_mode
  end

  # --- exclusivity invariant (Req 18.1, 18.6; Property 21) -----------------

  test "selecting server_playback tears down an active Cast_Session (Req 18.1)" do
    @user.update!(playback_mode: "client_cast")
    cast = CastSession.create!(user: @user, target_output_device_id: 7, current_song_id: 42, state: "playing")

    PlaybackMode.select(@user, "server_playback")

    assert_equal "stopped", cast.reload.state
    assert_not cast.active?
    assert PlaybackMode.exclusive?(@user)
  end

  test "selecting client_cast tears down an active Playback_Session (Req 18.1)" do
    @user.update!(playback_mode: "server_playback")
    playback = PlaybackSession.create!(user: @user, active_output_device_ids: [ 3 ], current_song_id: 42, state: "playing")

    PlaybackMode.select(@user, "client_cast")

    assert_equal "stopped", playback.reload.state
    assert_not playback.active?
    assert PlaybackMode.exclusive?(@user)
  end

  test "never leaves both session kinds active at once (Property 21)" do
    # Start with both a lingering cast and playback session, one active.
    cast = CastSession.create!(user: @user, target_output_device_id: 7, state: "playing")
    playback = PlaybackSession.create!(user: @user, active_output_device_ids: [ 3 ], state: "stopped")

    # Switch to server_playback: the cast session must be stopped.
    PlaybackMode.select(@user, "server_playback")
    refute cast.reload.active? && playback.reload.active?,
      "expected at most one session active after selecting server_playback"

    # And back to client_cast: whatever playback session was active must stop.
    playback.update!(state: "playing")
    PlaybackMode.select(@user, "client_cast")
    refute cast.reload.active? && playback.reload.active?,
      "expected at most one session active after selecting client_cast"
  end

  test "exclusive? is true when the other mode's session does not exist" do
    @user.update!(playback_mode: "client_cast")
    assert PlaybackMode.exclusive?(@user)
  end

  test "exclusive? is false when the other mode's session is active" do
    @user.update!(playback_mode: "client_cast")
    PlaybackSession.create!(user: @user, active_output_device_ids: [ 3 ], state: "playing")

    assert_not PlaybackMode.exclusive?(@user)
  end

  test "for creates a managed Cast_Session so a client_cast activity is never unmanaged (Req 18.6)" do
    @user.update!(playback_mode: "client_cast")
    assert_nil CastSession.find_by(user: @user)

    session = PlaybackMode.for(@user)
    assert session.persisted?
    assert_equal :cast_session, PlaybackMode.manager(@user)
  end
end
