# frozen_string_literal: true

require "test_helper"

# Property-based test for the Source_Preference half of Property 19 of the
# multi-server-library-sharing feature.
#
# Design property (multi-server-library-sharing, Property 19):
#   For any submitted Source_Preference value, the Server SHALL persist it and
#   apply it if and only if it is `prefer_own_server` or
#   `prefer_highest_quality`, otherwise rejecting it and leaving the existing
#   value unchanged (Req 11.10).
#
# This test drives the User#source_preference setting (has_setting +
# `validates :source_preference, inclusion: { in: SOURCE_PREFERENCE_OPTIONS },
# allow_nil: true`). Starting from a User with a known current
# Source_Preference, it attempts to assign a generated candidate value and
# save, asserting:
#   * (persist-and-apply) when the candidate is one of the two supported
#     values, the User is valid, the save succeeds, and after reload the
#     persisted Source_Preference equals the candidate; and
#   * (reject-and-preserve) when the candidate is any other non-nil value, the
#     User is invalid, the save fails, and after reload the persisted
#     Source_Preference is unchanged from the known current value.
#
# nil is intentionally excluded from the invalid candidates: `allow_nil: true`
# makes nil valid, and the has_setting reader collapses a nil stored value to
# the default, so a nil candidate is not an "invalid value" for this property.
class SourcePreferenceValidationPropertyTest < ActiveSupport::TestCase
  VALID_VALUES = User::SOURCE_PREFERENCE_OPTIONS

  # Feature: multi-server-library-sharing, Property 19: Preference and playback-mode value validation
  test "source_preference persists and applies iff a supported value, else is rejected leaving the existing value unchanged" do
    check_property(iterations: 120) do
      # A known starting Source_Preference, always one of the supported values.
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
            "prefer_own", "prefer_highest", "prefer_own_serve",
            "prefer_own_servers", "prefer_quality", "prefer_highest_qualit",
            "prefer_own_server ", " prefer_own_server", "prefer-own-server"
          )
        when :invalid_case
          choose(
            "PREFER_OWN_SERVER", "Prefer_Own_Server",
            "PREFER_HIGHEST_QUALITY", "Prefer_Highest_Quality"
          )
        else # :invalid_whitespace
          choose(" ", "  ", "\t", "\n")
        end

      [ current, candidate ]
    end.check do |(current, candidate)|
      user = User.create!(
        email: "prop19-src-#{SecureRandom.uuid}@example.com",
        password: "foobar123",
        source_preference: current
      )
      # Sanity: the known current value is persisted and applied.
      user.reload
      assert_equal current, user.source_preference

      expected_valid = VALID_VALUES.include?(candidate)

      user.source_preference = candidate
      saved = user.save

      if expected_valid
        # persist-and-apply: supported value is accepted, saved, and applied.
        assert saved, "expected save to succeed for supported value #{candidate.inspect}"
        assert user.valid?, "expected user to be valid for supported value #{candidate.inspect}"
        user.reload
        assert_equal candidate, user.source_preference,
          "expected supported value #{candidate.inspect} to be persisted and applied"
      else
        # reject-and-preserve: unsupported value is rejected and the existing
        # value is left unchanged.
        refute saved, "expected save to fail for unsupported value #{candidate.inspect}"
        refute user.valid?, "expected user to be invalid for unsupported value #{candidate.inspect}"
        assert_includes user.errors.attribute_names, :source_preference,
          "expected a source_preference validation error for #{candidate.inspect}"
        user.reload
        assert_equal current, user.source_preference,
          "expected existing value #{current.inspect} to be unchanged after rejecting #{candidate.inspect}"
      end
    end
  end
end
