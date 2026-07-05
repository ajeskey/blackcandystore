# frozen_string_literal: true

require "test_helper"

# Property-based test for the Playback_Mode half of Property 19 of the
# multi-server-library-sharing feature.
#
# Design property (multi-server-library-sharing, Property 19):
#   For any submitted Playback_Mode value, the Server SHALL record it and apply
#   it if and only if it is `client_cast` or `server_playback`, otherwise
#   rejecting it and leaving the existing mode unchanged (Req 16.4).
#
# This test drives the User#playback_mode setting (has_setting +
# `validates :playback_mode, inclusion: { in: PLAYBACK_MODE_OPTIONS },
# allow_nil: true`). Starting from a User with a known current Playback_Mode,
# it attempts to assign a generated candidate value and save, asserting:
#   * (record-and-apply) when the candidate is one of the two supported values,
#     the User is valid, the save succeeds, and after reload the persisted
#     Playback_Mode equals the candidate; and
#   * (reject-and-preserve) when the candidate is any other non-nil value, the
#     User is invalid, the save fails, and after reload the persisted
#     Playback_Mode is unchanged from the known current value.
#
# nil is intentionally excluded from the invalid candidates: `allow_nil: true`
# makes nil valid, and the has_setting reader collapses a nil stored value to
# the default, so a nil candidate is not an "invalid value" for this property.
class PlaybackModeValidationPropertyTest < ActiveSupport::TestCase
  VALID_VALUES = User::PLAYBACK_MODE_OPTIONS

  # Feature: multi-server-library-sharing, Property 19: Preference and playback-mode value validation
  test "playback_mode records and applies iff a supported value, else is rejected leaving the existing mode unchanged" do
    check_property(iterations: 120) do
      # A known starting Playback_Mode, always one of the supported values.
      current = choose(*VALID_VALUES)

      # A candidate value to submit: either a supported value (valid) or one of
      # several flavors of unsupported string (invalid).
      kind = choose(:valid, :invalid_random, :invalid_empty, :invalid_near_miss, :invalid_case, :invalid_whitespace)
      candidate =
        case kind
        when :valid
          choose(*VALID_VALUES)
        when :invalid_random
          # Random alpha string; never contains underscores so it can never
          # collide with a supported value.
          sized(range(1, 16)) { string(:alpha) }
        when :invalid_empty
          ""
        when :invalid_near_miss
          choose(
            "client", "cast", "client_cas", "client_casts",
            "server_play", "server_playbac", "server_playbacks",
            "client_cast ", " client_cast", "client-cast", "server-playback"
          )
        when :invalid_case
          choose(
            "CLIENT_CAST", "Client_Cast",
            "SERVER_PLAYBACK", "Server_Playback"
          )
        else # :invalid_whitespace
          choose(" ", "  ", "\t", "\n")
        end

      [ current, candidate ]
    end.check do |(current, candidate)|
      user = User.create!(
        email: "prop19-pbm-#{SecureRandom.uuid}@example.com",
        password: "foobar123",
        playback_mode: current
      )
      # Sanity: the known current value is persisted and applied.
      user.reload
      assert_equal current, user.playback_mode

      expected_valid = VALID_VALUES.include?(candidate)

      user.playback_mode = candidate
      saved = user.save

      if expected_valid
        # record-and-apply: supported value is accepted, saved, and applied.
        assert saved, "expected save to succeed for supported value #{candidate.inspect}"
        assert user.valid?, "expected user to be valid for supported value #{candidate.inspect}"
        user.reload
        assert_equal candidate, user.playback_mode,
          "expected supported value #{candidate.inspect} to be recorded and applied"
      else
        # reject-and-preserve: unsupported value is rejected and the existing
        # mode is left unchanged.
        refute saved, "expected save to fail for unsupported value #{candidate.inspect}"
        refute user.valid?, "expected user to be invalid for unsupported value #{candidate.inspect}"
        assert_includes user.errors.attribute_names, :playback_mode,
          "expected a playback_mode validation error for #{candidate.inspect}"
        user.reload
        assert_equal current, user.playback_mode,
          "expected existing mode #{current.inspect} to be unchanged after rejecting #{candidate.inspect}"
      end
    end
  end
end
