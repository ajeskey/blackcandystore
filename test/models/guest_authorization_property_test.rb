# frozen_string_literal: true

require "test_helper"

# Property-based test for the live-state gating seam of GuestAccessResolver
# (design Property 16; Req 5.6, 5.8, 8.4, 12.2).
#
# Property 16 concerns *only* whether a request bearing a Guest_Token is still
# authorized given the live state of the session and the Guest:
#
#   * a request is authorized iff the session is `active`, the session has not
#     expired, and the Guest has not been removed; and
#   * once the session ends or its Session_Duration expires, or the Guest is
#     removed, every subsequent request from that Guest — including a
#     previously-admitted one — is rejected.
#
# It exercises both faces of the seam:
#
#   * the pure `request_authorized?(session_active:, session_expired:,
#     guest_removed:)` over the full 2^3 boolean space, asserting it equals the
#     conjunction `session_active AND NOT session_expired AND NOT guest_removed`
#     so that any single failing condition rejects; and
#   * the record-based `access_valid?(session:, guest:, now:)` against real
#     Party_Session / Co_Listen_Session records with real admitted Guests, where
#     the three conditions are realized as genuine state: the session `ended`
#     vs `active`, expiry driven off a backing Access_Grant's `expires_at`
#     (past = expired, future or perpetual/nil = not expired), and the Guest
#     removed vs not. The record-based decision must agree with the pure one.
#
# Each iteration rebuilds its own feature records (see reset_feature_data!) so a
# previously-admitted Guest is observed losing access purely because state
# flipped, never because of leakage between iterations.
class GuestAuthorizationPropertyTest < ActiveSupport::TestCase
  # Feature: radio-party-colisten, Property 16: Guest authorization depends on live session and guest state
  test "a Guest_Token request is authorized iff the session is active and not expired and the Guest not removed, and any one failing condition rejects, for both the pure decision and the record-based decision on real sessions and guests" do
    check_property(iterations: 100) do
      # The three live-state conditions realized independently, plus the session
      # kind and, when the session is not expired, whether "not expired" is a
      # future expiry or a perpetual (no-expiry) grant — both must count as not
      # expired (Req 4.5, 4.6 / 8.3 perpetual; 8.4 future).
      session_active = choose(true, false)
      session_expired = choose(true, false)
      guest_removed = choose(true, false)
      kind = choose("party", "co_listen")
      perpetual_when_unexpired = choose(true, false)

      [ session_active, session_expired, guest_removed, kind, perpetual_when_unexpired ]
    end.check do |(session_active, session_expired, guest_removed, kind, perpetual_when_unexpired)|
      expected = session_active && !session_expired && !guest_removed

      # --- pure decision over the boolean space (Property 16) ---
      assert_equal expected,
        GuestAccessResolver.request_authorized?(
          session_active: session_active,
          session_expired: session_expired,
          guest_removed: guest_removed
        ),
        "request_authorized? must be active AND NOT expired AND NOT removed " \
          "(active=#{session_active}, expired=#{session_expired}, removed=#{guest_removed})"

      # --- record-based decision on real sessions and guests (Property 16) ---
      reset_feature_data!
      now = Time.current
      host = build_host

      session = build_session(kind, host)
      # Realize the session's live state: ended vs active.
      session.update!(state: session_active ? "active" : "ended")

      # Realize expiry off a backing Access_Grant's expires_at, wired through a
      # Share_Link so GuestAccessResolver#session_expires_at can read it:
      #   * expired      -> a grant that has already expired (past)
      #   * not expired  -> a future expiry, or a perpetual (nil) expiry
      expires_at =
        if session_expired
          now - 1.hour
        elsif perpetual_when_unexpired
          nil
        else
          now + 1.hour
        end
      attach_backing_grant(session, host, expires_at)

      # A genuinely admitted Guest bound to a Guest_Token, then removed or not.
      guest = admit_guest(session, now)
      guest.remove!(now) if guest_removed

      actual = GuestAccessResolver.access_valid?(session: session, guest: guest.reload, now: now)

      assert_equal expected, actual,
        "access_valid? must agree with the live-state conjunction " \
          "(kind=#{kind}, active=#{session_active}, expired=#{session_expired}, " \
          "perpetual=#{perpetual_when_unexpired}, removed=#{guest_removed})"

      # Cross-check the record-based expiry against the pure input so an expired
      # session is genuinely observed as expired (and a perpetual/future one is
      # not) rather than the two decisions agreeing by accident.
      assert_equal session_expired, GuestAccessResolver.session_expired?(session, now: now),
        "the backing grant must make the session expired iff session_expired was requested"
    end
  end

  private

  # A fresh Host user per iteration so no session/guest state leaks between
  # generated cases.
  def build_host
    User.create!(email: "guest-authz-host-#{SecureRandom.uuid}@example.com", password: "foobar123")
  end

  # Build the requested session kind for `host`, scoped to no shared libraries
  # (library scoping is Property 15's concern, not this one).
  def build_session(kind, host)
    if kind == "party"
      PartySession.create!(user: host, shared_library_ids: [])
    else
      CoListenSession.create!(user: host, shared_library_ids: [])
    end
  end

  # Wire a Share_Link backed by an AccessGrant with the given expiration onto
  # `session`, so GuestAccessResolver reads expiry from real records.
  def attach_backing_grant(session, host, expires_at)
    grant = AccessGrant.create!(
      library: default_library,
      token: "guest-authz-grant-#{SecureRandom.hex(6)}",
      expires_at: expires_at
    )
    ShareLink.create!(sessionable: session, access_grant: grant)
    grant
  end

  # Create a real admitted Guest bound to a fresh Guest_Token.
  def admit_guest(session, now)
    guest = session.guests.new(admitted_at: now, add_count: 0)
    guest.token = SecureRandom.urlsafe_base64(32)
    guest.save!
    guest
  end

  def default_library
    libraries(:default_library)
  end

  # Remove every feature record touched by this property, ordered to respect
  # foreign keys, so each iteration observes only the session/guest it builds.
  def reset_feature_data!
    Guest.delete_all
    ShareLink.delete_all
    PartySession.delete_all
    CoListenSession.delete_all
    AccessGrant.delete_all
    User.where("email LIKE ?", "guest-authz-host-%@example.com").delete_all
  end
end
