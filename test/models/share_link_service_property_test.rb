# frozen_string_literal: true

require "test_helper"

# Property-based test for Property 12 of the radio-party-colisten feature.
#
# Design property (radio-party-colisten, Property 12):
#   For any Session_Duration, the backing Access_Grant's `expires_at` equals
#   `created_at + duration` when the duration is a number of hours or days, and
#   is nil when the duration is `perpetual`.
#
#   Validates: Requirements 4.4, 4.5, 8.3
#
# ShareLinkService owns the single seam that translates a session's
# Session_Duration into the backing AccessGrant's `expires_at`. This test
# exercises that mapping two ways:
#
#   1. The pure `ShareLinkService.expires_at_for(kind:, value:, created_at:)`
#      function directly, across generated `hours`/`days` values and
#      `perpetual`, and
#   2. `ShareLinkService.generate(session, now:)`, asserting every backing
#      AccessGrant it mints carries exactly that computed expiration.
#
# The generator draws the duration kind, a positive hours/days value, and a
# reference `created_at` (a base time shifted by a signed offset) so the
# addition is exercised across a wide range of reference times, and randomly
# targets a Party_Session or a Co_Listen_Session since both share the seam.
class ShareLinkServicePropertyTest < ActiveSupport::TestCase
  MEDIA_PATH = Rails.root.join("test", "fixtures", "files").to_s
  # A fixed, timezone-explicit reference the generated offset is measured from,
  # so the expected `created_at + duration` arithmetic is fully deterministic.
  BASE_TIME = Time.utc(2025, 1, 1, 12, 0, 0)
  # Slack (seconds) tolerated when comparing computed expirations, covering any
  # sub-second representation differences without weakening the property.
  TIME_TOLERANCE = 1.0

  setup do
    @host = User.create!(email: "prop12-host-#{SecureRandom.uuid}@example.com", password: "foobar123")
    # The host's authorized libraries are the local libraries it owns; the
    # session shares (a subset of) these, and each shared library yields one
    # backing AccessGrant.
    @shared_ids = Array.new(2) { create_local_library(owner: @host).id }
  end

  # Feature: radio-party-colisten, Property 12: Session duration maps to grant expiration
  test "session duration maps to backing grant expiration: created_at + duration for hours/days, nil for perpetual" do
    check_property(iterations: 100) do
      kind = choose("hours", "days", "perpetual")
      value = range(1, 1000)                 # positive; only meaningful for hours/days
      offset_seconds = range(-1_000_000, 1_000_000)
      klass_name = choose("PartySession", "CoListenSession")
      [ kind, value, offset_seconds, klass_name ]
    end.check do |(kind, value, offset_seconds, klass_name)|
      reset_sessions!

      created_at = BASE_TIME + offset_seconds
      # `perpetual` carries no value; hours/days carry the positive value.
      effective_value = kind == "perpetual" ? nil : value

      expected = case kind
      when "hours" then created_at + value.hours
      when "days" then created_at + value.days
      when "perpetual" then nil
      end

      # --- 1. pure mapping -------------------------------------------------
      mapped = ShareLinkService.expires_at_for(
        kind: kind, value: effective_value, created_at: created_at
      )
      assert_expiration expected, mapped,
        "expires_at_for(kind=#{kind.inspect}, value=#{effective_value.inspect}) must be created_at + duration (nil for perpetual)"

      # --- 2. generate(session) sets each backing grant's expires_at -------
      session = build_session(klass_name, kind: kind, value: effective_value)
      links = ShareLinkService.generate(session, now: created_at)

      assert_equal @shared_ids.length, links.length,
        "generate must mint one Share_Link (one backing grant) per shared library"

      links.each do |link|
        assert_expiration expected, link.access_grant.expires_at,
          "#{klass_name} #{kind} duration must set the backing grant's expires_at to created_at + duration (nil for perpetual)"
      end
    end
  end

  private

  # Assert an expiration matches the expected value: nil is exact, otherwise
  # compare instants within a sub-second tolerance.
  def assert_expiration(expected, actual, message)
    if expected.nil?
      assert_nil actual, message
    else
      assert_not_nil actual, message
      assert_in_delta expected.to_f, actual.to_f, TIME_TOLERANCE, message
    end
  end

  # Persist a valid session of the given kind sharing the host's libraries with
  # the requested Session_Duration, so `generate` can attach Share_Links to it.
  def build_session(klass_name, kind:, value:)
    klass_name.constantize.create!(
      user: @host,
      shared_library_ids: @shared_ids,
      session_duration_kind: kind,
      session_duration_value: value
    )
  end

  # Clear the per-iteration session/link/grant records while keeping the host
  # and its libraries from setup, so each iteration observes a clean slate.
  def reset_sessions!
    ShareLink.delete_all
    AccessGrant.delete_all
    PartySession.delete_all
    CoListenSession.delete_all
  end

  def create_local_library(owner:)
    Library.create!(
      name: "Prop12-#{SecureRandom.uuid}",
      kind: "local",
      media_path: MEDIA_PATH,
      owner:
    )
  end
end
