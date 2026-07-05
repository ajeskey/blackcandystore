# frozen_string_literal: true

require "test_helper"

# Property-based test for Property 20 of the multi-server-library-sharing
# feature.
#
# Design property (multi-server-library-sharing, Property 20):
#   For any sequence of control operations applied to a Playback_Session or
#   Cast_Session:
#     (a) the session state is ALWAYS exactly one of stopped/playing/paused
#         (state invariant, Req 14.15 / 17.14);
#     (b) a play or resume on a session with NO active Output_Device is rejected
#         leaving the state unchanged (Req 14.14 / 17.11);
#     (c) when the last active Output_Device becomes unavailable during
#         `playing` the state becomes `stopped` (Req 14.11, 14.12 / 17.12);
#     (d) a resume applied immediately after a pause returns to `playing` with
#         the SAME current song and playback position retained (Req 14.16 /
#         17.16).
#
# The Playback_Session side of the property drives the PlaybackController state
# machine (task 24.1); the Cast_Session side drives CastSession's client-cast
# state machine (task 25.1). Both are exercised because the property is stated
# over "a Playback_Session or Cast_Session".
class SessionStateMachinePropertyTest < ActiveSupport::TestCase
  STATES = %w[stopped playing paused].freeze

  # Device ids the injected reachability resolver treats as reachable so
  # `select_devices` can succeed without Device_Discovery or OutputDevice rows.
  REACHABLE_DEVICE_IDS = [ 1, 2, 3 ].freeze

  # PlaybackController operations exercised by the sequence.
  PLAYBACK_OPS = %i[select_none select_devices play resume pause stop set_volume device_unavailable].freeze
  # CastSession operations exercised by the sequence.
  CAST_OPS = %i[clear_target set_target play resume pause stop output_device_unavailable].freeze

  # Feature: multi-server-library-sharing, Property 20: Playback and cast sessions maintain a valid state and correct resume transition
  test "PlaybackController maintains a valid state and correct resume-after-pause transition under random control sequences" do
    check_property(iterations: 100) do
      # A random length-5..20 sequence of control operations, each with the
      # arguments it needs. Device selection covers both the "has device" and
      # "no device" states so (b) is genuinely exercised.
      ops = Array.new(range(5, 20)) do
        op = PLAYBACK_OPS.sample
        case op
        when :select_devices
          # A non-empty reachable subset (order/duplicates handled by the controller).
          [ op, REACHABLE_DEVICE_IDS.sample(range(1, REACHABLE_DEVICE_IDS.length)) ]
        when :play
          [ op, range(1, 50), range(0, 300) ] # song_id, position
        when :set_volume
          [ op, range(0, 100) ]
        when :device_unavailable
          [ op, REACHABLE_DEVICE_IDS.sample ]
        else
          [ op ]
        end
      end
      [ ops ]
    end.check do |(ops)|
      user = build_user
      controller = PlaybackController.new(
        PlaybackSession.create!(user: user, state: "stopped"),
        reachable: ->(id) { REACHABLE_DEVICE_IDS.include?(id.to_i) }
      )
      session = controller.session

      ops.each do |op, *args|
        pre_state = session.state
        pre_song = session.current_song_id
        pre_position = session.position
        had_devices = session.active_output_device_ids.any?

        case op
        when :select_none
          controller.select_devices([])
        when :select_devices
          controller.select_devices(args[0])
        when :play
          result = controller.play(song_id: args[0], position: args[1])
          # (b) play with no active device is rejected, state unchanged.
          unless had_devices
            assert result.rejected?, "play with no active device should be rejected"
            assert_equal pre_state, session.state, "rejected play must not change state"
          end
        when :resume
          result = controller.resume
          unless had_devices
            # (b) resume with no active device is rejected, state unchanged.
            assert result.rejected?, "resume with no active device should be rejected"
            assert_equal pre_state, session.state, "rejected resume must not change state"
          end
          if had_devices && pre_state == "paused" && !pre_song.nil?
            # (d) resume immediately after pause returns to playing retaining
            # the exact current song and playback position.
            assert result.ok?, "resume from paused with a device and current song should succeed"
            assert_equal "playing", session.state
            assert_equal pre_song, session.current_song_id, "resume must retain current song"
            assert_equal pre_position, session.position, "resume must retain playback position"
          end
        when :pause
          controller.pause
        when :stop
          controller.stop
        when :set_volume
          controller.set_volume(args[0])
        when :device_unavailable
          remaining = session.active_output_device_ids - [ args[0].to_i ]
          removed_last_while_playing = pre_state == "playing" && had_devices &&
                                       remaining.empty? &&
                                       session.active_output_device_ids.include?(args[0].to_i)
          controller.device_unavailable(args[0])
          if removed_last_while_playing
            # (c) losing the last active device while playing -> stopped.
            assert_equal "stopped", session.state,
              "losing the last active device while playing must stop playback"
          end
        end

        # (a) the state invariant holds after every operation.
        assert_includes STATES, session.state, "state must always be one of #{STATES.inspect}"
      end
    end
  end

  # Feature: multi-server-library-sharing, Property 20: Playback and cast sessions maintain a valid state and correct resume transition
  test "CastSession maintains a valid state and correct resume-after-pause transition under random control sequences" do
    check_property(iterations: 100) do
      ops = Array.new(range(5, 20)) do
        op = CAST_OPS.sample
        case op
        when :set_target
          [ op, range(1, 5) ] # target_output_device_id
        when :play
          [ op, range(1, 50), range(0, 300) ] # song_id, position
        when :output_device_unavailable
          [ op, range(1, 5) ]
        else
          [ op ]
        end
      end
      [ ops ]
    end.check do |(ops)|
      user = build_user
      session = CastSession.create!(user: user, state: "stopped")

      ops.each do |op, *args|
        pre_state = session.state
        pre_song = session.current_song_id
        pre_position = session.position
        has_target = session.target_output_device_id.present?

        case op
        when :clear_target
          session.target_output_device_id = nil
        when :set_target
          session.target_output_device_id = args[0]
        when :play
          applied = session.play(song_id: args[0], position: args[1])
          unless has_target
            # (b) play with no target device is rejected, state unchanged.
            assert_equal false, applied, "play with no target device should be rejected"
            assert_equal pre_state, session.state, "rejected play must not change state"
          end
        when :resume
          applied = session.resume
          unless has_target
            # (b) resume with no target device is rejected, state unchanged.
            assert_equal false, applied, "resume with no target device should be rejected"
            assert_equal pre_state, session.state, "rejected resume must not change state"
          end
          if has_target && pre_state == "paused"
            # (d) resume immediately after pause returns to playing retaining
            # the exact current song and playback position.
            assert_equal true, applied, "resume from paused with a target should succeed"
            assert_equal "playing", session.state
            assert session.current_song_id == pre_song,
              "resume must retain current song (expected #{pre_song.inspect}, got #{session.current_song_id.inspect})"
            assert_equal pre_position, session.position, "resume must retain playback position"
          end
        when :pause
          session.pause
        when :stop
          session.stop
        when :output_device_unavailable
          removed_target_while_playing = pre_state == "playing" &&
                                         has_target &&
                                         args[0].to_i == session.target_output_device_id
          session.output_device_unavailable(args[0])
          if removed_target_while_playing
            # (c) the (single/last) target device becoming unavailable while
            # playing -> stopped.
            assert_equal "stopped", session.state,
              "losing the target device while playing must stop casting"
          end
        end

        # (a) the state invariant holds after every operation.
        assert_includes STATES, session.state, "state must always be one of #{STATES.inspect}"
      end
    end
  end

  private

  # A fresh, persisted User for each generated sequence so the per-user unique
  # session rows never collide across iterations.
  def build_user
    User.create!(email: "prop20-#{SecureRandom.uuid}@example.com", password: "foobar123")
  end
end
