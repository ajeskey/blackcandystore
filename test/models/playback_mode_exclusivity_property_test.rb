# frozen_string_literal: true

require "test_helper"

# Property-based test for Property 21 of the multi-server-library-sharing
# feature (Req 16, 18).
#
# Design property (multi-server-library-sharing, Property 21):
#   For any set of concurrent playback activities, each activity SHALL be
#   classified as exactly one Playback_Mode; a `client_cast` activity is
#   managed by a Cast_Session (client audio source, not server); a
#   `server_playback` activity by a Playback_Session (server audio source, not
#   client); NO activity is managed by BOTH a Cast_Session and a
#   Playback_Session; every concurrent `client_cast` activity is managed.
#
# The property is exercised over a set of concurrent Users, each starting in a
# randomly chosen Playback_Mode and driven through a random sequence of mode
# selections/switches via PlaybackMode.select. Before every selection the
# currently-managing session is made active (`playing`) so each switch has to
# tear down a genuinely-active session of the previously-selected mode — this
# is what stresses the exclusivity invariant.
class PlaybackModeExclusivityPropertyTest < ActiveSupport::TestCase
  MODES = User::PLAYBACK_MODE_OPTIONS # %w[client_cast server_playback]

  # Feature: multi-server-library-sharing, Property 21: Playback mode is exclusive and determines the audio source
  test "playback mode is exclusive and determines the audio source across concurrent activities" do
    check_property(iterations: 100) do
      # A set of concurrent playback activities: each is one User with an
      # initial Playback_Mode plus a random sequence of mode selections. Modes
      # are sampled from BOTH options so client_cast<->server_playback switches
      # (and same-mode re-selections) both occur.
      activities = Array.new(range(1, 5)) do
        initial = MODES.sample
        switches = Array.new(range(1, 6)) { MODES.sample }
        [ initial, switches ]
      end
      [ activities ]
    end.check do |(activities)|
      activities.each do |initial, switches|
        user = build_user(initial)
        # The initial activity is genuinely active under its starting mode.
        activate_current_session(user)

        switches.each do |mode|
          PlaybackMode.select(user, mode)
          # Re-activate the now-managing session so the NEXT switch must tear
          # down an active session (exercises previously-active-session teardown).
          activate_current_session(user)
        end

        assert_playback_mode_invariants(user)
      end
    end
  end

  private

  # A fresh, persisted User per generated activity so the per-user unique
  # session rows never collide across iterations or concurrent activities.
  def build_user(mode)
    User.create!(
      email: "prop21-#{SecureRandom.uuid}@example.com",
      password: "foobar123",
      playback_mode: mode
    )
  end

  # Make the session that manages the User's current Playback_Mode active
  # (`playing`) so it is a live activity that a subsequent mode switch must tear
  # down. Under client_cast that is the Cast_Session; under server_playback the
  # Playback_Session.
  def activate_current_session(user)
    session = PlaybackMode.session_for(user)

    case session
    when CastSession
      session.update!(target_output_device_id: 7, current_song_id: 42, state: "playing")
    when PlaybackSession
      session.update!(active_output_device_ids: [ 3 ], current_song_id: 42, state: "playing")
    end
  end

  # Assert every clause of Property 21 for a single activity (User).
  def assert_playback_mode_invariants(user)
    mode = user.reload.playback_mode
    audio = PlaybackMode.audio_source(user)
    manager = PlaybackMode.manager(user)

    # (a) Classified as exactly one Playback_Mode: the mode is one of the two
    # supported options and its audio source / managing session kind are each
    # exactly one of the defined values.
    assert_includes MODES, mode, "activity must be classified as one Playback_Mode"
    assert_includes %w[client server], audio, "audio source must be exactly one of client/server"
    assert_includes %i[cast_session playback_session], manager,
      "manager must be exactly one of cast_session/playback_session"

    session = PlaybackMode.session_for(user)

    if mode == "client_cast"
      # (b) client_cast -> managed by a Cast_Session; client audio source, NOT server.
      assert_instance_of CastSession, session
      assert_equal :cast_session, manager
      assert_equal "client", audio
      refute_equal "server", audio, "a client_cast activity's audio source is not the server"
      # (d) every client_cast activity is managed (session_for returns a session).
      assert session.persisted?, "a client_cast activity must be managed by a persisted Cast_Session"
      other = PlaybackSession.find_by(user: user)
    else
      # (b) server_playback -> managed by a Playback_Session; server audio source, NOT client.
      assert_instance_of PlaybackSession, session
      assert_equal :playback_session, manager
      assert_equal "server", audio
      refute_equal "client", audio, "a server_playback activity's audio source is not the client"
      assert session.persisted?, "a server_playback activity must be managed by a persisted Playback_Session"
      other = CastSession.find_by(user: user)
    end

    # (c) Exclusivity: NO activity is managed by BOTH a Cast_Session and a
    # Playback_Session — the other mode's session is stopped (idle), so at most
    # one session kind actively manages the activity.
    assert PlaybackMode.exclusive?(user), "activity must not be managed by both session kinds"
    assert(other.nil? || !other.active?, "the other mode's session must not be active")
  end
end
