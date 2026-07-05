# frozen_string_literal: true

require "test_helper"

class PlaybackSessionTest < ActiveSupport::TestCase
  setup do
    @user = users(:admin)
  end

  def build_session(**attrs)
    PlaybackSession.new(user: @user, **attrs)
  end

  test "belongs to a user (Req 14.1)" do
    session = build_session
    assert_equal @user, session.user
  end

  test "requires a user" do
    session = build_session(user: nil)
    assert_not session.valid?
    assert_includes session.errors.attribute_names, :user
  end

  test "defaults state to stopped (Req 14.15)" do
    session = build_session
    session.save!
    assert_equal "stopped", session.reload.state
  end

  test "defaults position to 0" do
    session = build_session
    session.save!
    assert_equal 0, session.reload.position
  end

  test "keeps state in exactly one of stopped/playing/paused (Req 14.15)" do
    PlaybackSession::STATES.each do |state|
      assert build_session(state: state).valid?, "expected #{state} to be valid"
    end

    assert_not build_session(state: "buffering").valid?
  end

  test "serializes active_output_device_ids as an array (Req 14.15)" do
    session = build_session(active_output_device_ids: [ 1, 2, 3 ])
    session.save!
    assert_equal [ 1, 2, 3 ], session.reload.active_output_device_ids
  end

  test "returns an empty array for active_output_device_ids when unset" do
    session = build_session
    session.save!
    assert_equal [], session.reload.active_output_device_ids
  end

  test "retains the current song and position across a save (Req 14.16)" do
    session = build_session(state: "paused", current_song_id: 99, position: 42)
    session.save!

    reloaded = session.reload
    assert_equal 99, reloaded.current_song_id
    assert_equal 42, reloaded.position
    assert_equal "paused", reloaded.state
  end
end
