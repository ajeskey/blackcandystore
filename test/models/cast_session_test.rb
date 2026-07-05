# frozen_string_literal: true

require "test_helper"

class CastSessionTest < ActiveSupport::TestCase
  setup do
    @user = users(:admin)
  end

  def build_session(**attrs)
    CastSession.new(user: @user, **attrs)
  end

  # --- Persistence / validations -------------------------------------------

  test "belongs to a user (Req 17.1)" do
    assert_equal @user, build_session.user
  end

  test "requires a user" do
    session = build_session(user: nil)
    assert_not session.valid?
    assert_includes session.errors.attribute_names, :user
  end

  test "defaults state to stopped (Req 17.14)" do
    session = build_session
    session.save!
    assert_equal "stopped", session.reload.state
  end

  test "defaults position to 0" do
    session = build_session
    session.save!
    assert_equal 0, session.reload.position
  end

  test "keeps state in exactly one of stopped/playing/paused (Req 17.14)" do
    CastSession::STATES.each do |state|
      assert build_session(state: state).valid?, "expected #{state} to be valid"
    end

    assert_not build_session(state: "buffering").valid?
  end

  test "is one-per-user (unique index on user_id)" do
    build_session(target_output_device_id: 1).save!

    duplicate = build_session(target_output_device_id: 2)
    assert_raises(ActiveRecord::RecordNotUnique) { duplicate.save!(validate: false) }
  end

  # --- play (Req 17.5; Property 20) ----------------------------------------

  test "play with a target device moves to playing and sets the song (Req 17.5)" do
    session = build_session(target_output_device_id: 7)

    assert session.play(song_id: 42, position: 0)
    assert_equal "playing", session.state
    assert_equal 42, session.current_song_id
  end

  test "play with no target output device is rejected and leaves state unchanged (Property 20)" do
    session = build_session(state: "stopped", current_song_id: nil, target_output_device_id: nil)

    assert_not session.play(song_id: 42)
    assert_equal "stopped", session.state
    assert_nil session.current_song_id
  end

  # --- pause / resume (Req 17.6, 17.16; Property 20) -----------------------

  test "pause retains the current song and position and moves to paused (Req 17.6)" do
    session = build_session(state: "playing", target_output_device_id: 7, current_song_id: 42, position: 33)

    assert session.pause
    assert_equal "paused", session.state
    assert_equal 42, session.current_song_id
    assert_equal 33, session.position
  end

  test "pause is a no-op when not playing" do
    session = build_session(state: "stopped", target_output_device_id: 7)

    assert_not session.pause
    assert_equal "stopped", session.state
  end

  test "resume after pause returns to playing with the same song and position (Req 17.16; Property 20)" do
    session = build_session(state: "playing", target_output_device_id: 7, current_song_id: 42, position: 33)
    session.pause

    assert session.resume
    assert_equal "playing", session.state
    assert_equal 42, session.current_song_id
    assert_equal 33, session.position
  end

  test "resume with no target output device is rejected and leaves state unchanged (Property 20)" do
    session = build_session(state: "paused", target_output_device_id: nil, current_song_id: 42, position: 33)

    assert_not session.resume
    assert_equal "paused", session.state
    assert_equal 42, session.current_song_id
    assert_equal 33, session.position
  end

  # --- stop (Req 17.7) ------------------------------------------------------

  test "stop clears the playback position and moves to stopped (Req 17.7)" do
    session = build_session(state: "playing", target_output_device_id: 7, current_song_id: 42, position: 33)

    assert session.stop
    assert_equal "stopped", session.state
    assert_equal 0, session.position
  end

  # --- device unavailability (Req 17.12; Property 20) ----------------------

  test "target device becoming unavailable while playing stops the session (Property 20)" do
    session = build_session(state: "playing", target_output_device_id: 7, current_song_id: 42, position: 33)

    assert session.output_device_unavailable(7)
    assert_equal "stopped", session.state
  end

  test "a non-target device becoming unavailable does not affect the session" do
    session = build_session(state: "playing", target_output_device_id: 7, current_song_id: 42, position: 33)

    assert_not session.output_device_unavailable(99)
    assert_equal "playing", session.state
  end

  test "device unavailability while not playing is a no-op" do
    session = build_session(state: "paused", target_output_device_id: 7, current_song_id: 42, position: 33)

    assert_not session.output_device_unavailable(7)
    assert_equal "paused", session.state
  end
end
