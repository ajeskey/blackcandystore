# frozen_string_literal: true

require "test_helper"

# Property-based test for Invite_Code expiration-duration validation.
#
# Design property (multi-server-library-sharing, Property 8):
#   For any requested expiration duration, the Invite_Manager SHALL create the
#   invite with `expires_at = created_at + duration` if and only if the duration
#   is between 1 minute and 365 days inclusive, and SHALL otherwise reject the
#   request without creating an Access_Grant.
#
# The bounds under test are InviteManager::MIN_EXPIRES_IN (1 minute = 60s) and
# InviteManager::MAX_EXPIRES_IN (365 days = 31_536_000s), inclusive.
#
# The generator produces integer-second durations spanning the interesting
# regions around those bounds:
#   * negative / zero durations (always out of range, below the minimum),
#   * strictly below the 1-minute minimum (1..59s),
#   * exactly the minimum (60s) and exactly the maximum (31_536_000s),
#   * strictly in range (60s..365d),
#   * strictly above the 365-day maximum.
#
# For an in-range duration the test freezes time so `Time.current + expires_in`
# is deterministic, then asserts exactly one Access_Grant was created whose
# `expires_at` equals `created_at + duration`. For an out-of-range duration it
# asserts InviteManager::InvalidExpiration is raised and the Access_Grant count
# is unchanged (no grant created).
class InviteExpirationValidationPropertyTest < ActiveSupport::TestCase
  # Inclusive bounds, in seconds, mirrored from InviteManager (Req 4.5, 4.8).
  MIN_SECONDS = InviteManager::MIN_EXPIRES_IN.to_i # 60
  MAX_SECONDS = InviteManager::MAX_EXPIRES_IN.to_i # 31_536_000

  # Feature: multi-server-library-sharing, Property 8: Invite expiration duration validation
  test "generate creates a grant with expires_at = created_at + duration iff duration is in [1 minute, 365 days]" do
    library = libraries(:default_library)
    owner = users(:visitor1)

    # default_library is owned by visitor1 per fixtures; ownership is required so
    # that generate reaches the expiration-range check rather than failing on
    # authorization first.
    assert_equal owner, library.owner,
      "test setup expects the default library to be owned by visitor1"

    check_property(iterations: 150) do
      # This block runs as a Rantly instance, so choose/range are on `self`.
      # Produce an integer number of seconds across / around the bounds.
      case choose(:negative_or_zero, :below_min, :exact_min, :in_range, :exact_max, :above_max)
      when :negative_or_zero
        range(-100_000, 0)
      when :below_min
        range(1, MIN_SECONDS - 1)
      when :exact_min
        MIN_SECONDS
      when :in_range
        range(MIN_SECONDS, MAX_SECONDS)
      when :exact_max
        MAX_SECONDS
      when :above_max
        range(MAX_SECONDS + 1, MAX_SECONDS * 2)
      end
    end.check do |seconds|
      duration = seconds.seconds
      in_range = seconds >= MIN_SECONDS && seconds <= MAX_SECONDS
      grants_before = AccessGrant.count

      if in_range
        # Freeze time so `created_at + duration` is deterministic and can be
        # compared exactly against the grant's recorded expiration.
        freeze_time do
          created_at = Time.current
          code = InviteManager.generate(library: library, owner: owner, expires_in: duration)

          assert_equal grants_before + 1, AccessGrant.count,
            "expected exactly one Access_Grant to be created for #{seconds}s"

          grant = AccessGrant.last
          assert grant.active?, "created grant should be active for #{seconds}s"
          assert_in_delta (created_at + duration).to_f, grant.expires_at.to_f, 1.0,
            "expires_at should equal created_at + #{seconds}s"

          # The returned Invite_Code must round-trip to the grant's token.
          decoded = InviteManager.decode(code)
          assert grant.authenticate_token(decoded[:secret_token]),
            "returned invite code should authenticate the created grant"
        end
      else
        assert_raises(InviteManager::InvalidExpiration,
          "expected #{seconds}s to be rejected as out-of-range") do
          InviteManager.generate(library: library, owner: owner, expires_in: duration)
        end

        assert_equal grants_before, AccessGrant.count,
          "no Access_Grant should be created for out-of-range duration #{seconds}s"
      end
    end
  end
end
