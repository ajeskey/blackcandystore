# frozen_string_literal: true

require "test_helper"

# Unit tests for the Guest model (Req 5.13, 8.7). Covers digest-only
# persistence of the Guest_Token, constant-time verification and lookup, the
# polymorphic sessionable association, and the quota/rate/removal helpers that
# enforce per-Guest limits (Req 5.8, 5.9).
class GuestTest < ActiveSupport::TestCase
  setup do
    @host = users(:visitor1)
    @session = PartySession.create!(user: @host, shared_library_ids: [])
  end

  def build_guest(token: "guest-secret", **attrs)
    Guest.new(sessionable: @session, token: token, **attrs)
  end

  # --- Association wiring --------------------------------------------------

  test "belongs polymorphically to the admitting session" do
    guest = build_guest
    assert guest.save
    assert_equal @session, guest.reload.sessionable
    assert_equal "PartySession", guest.sessionable_type
  end

  test "can be admitted to a Co_Listen_Session too" do
    co_listen = CoListenSession.create!(user: @host, shared_library_ids: [])
    guest = Guest.create!(sessionable: co_listen, token: "co-secret")
    assert_equal co_listen, guest.reload.sessionable
  end

  test "a session exposes its admitted guests through the has_many association" do
    guest = build_guest
    guest.save!
    assert_includes @session.guests, guest
  end

  test "requires a guest_token_digest" do
    guest = Guest.new(sessionable: @session)
    assert_not guest.valid?
    assert_includes guest.errors.attribute_names, :guest_token_digest
  end

  # --- Digest-only persistence (Req 8.7) -----------------------------------

  test "stores the token hashed rather than in plaintext" do
    guest = build_guest(token: "plaintext-guest")
    assert_not_nil guest.guest_token_digest
    assert_not_equal "plaintext-guest", guest.guest_token_digest
    assert_equal Guest.digest("plaintext-guest"), guest.guest_token_digest
  end

  test "retains the plaintext token only in memory and never after reload" do
    guest = build_guest(token: "one-time-secret")
    guest.save!
    assert_equal "one-time-secret", guest.token
    assert_nil Guest.find(guest.id).token
  end

  test "digest is deterministic for the same token and differs for different tokens" do
    assert_equal Guest.digest("tok-a"), Guest.digest("tok-a")
    assert_not_equal Guest.digest("tok-a"), Guest.digest("tok-b")
  end

  # --- Constant-time verification and lookup -------------------------------

  test "authenticate_token verifies with a constant-time comparison" do
    guest = build_guest(token: "right-guest-token")
    assert guest.authenticate_token("right-guest-token")
    assert_not guest.authenticate_token("wrong-token")
    assert_not guest.authenticate_token(nil)
    assert_not guest.authenticate_token("")
  end

  test "find_by_token returns the matching guest" do
    guest = build_guest(token: "lookup-guest")
    guest.save!
    assert_equal guest, Guest.find_by_token("lookup-guest")
  end

  test "find_by_token returns nil for an unknown or blank token" do
    build_guest(token: "known-guest").save!
    assert_nil Guest.find_by_token("no-such-guest")
    assert_nil Guest.find_by_token(nil)
    assert_nil Guest.find_by_token("")
  end

  # --- Removal helpers (Req 5.8) -------------------------------------------

  test "a fresh guest is active and not removed" do
    guest = build_guest
    guest.save!
    assert guest.active?
    assert_not guest.removed?
  end

  test "remove! marks the guest removed and is idempotent" do
    guest = build_guest
    guest.save!

    freeze_time = Time.current
    guest.remove!(freeze_time)
    assert guest.removed?
    assert_not guest.active?
    first_removed_at = guest.reload.removed_at

    guest.remove!(freeze_time + 1.hour)
    assert_equal first_removed_at.to_i, guest.reload.removed_at.to_i,
      "re-removing must keep the original removal time"
  end

  # --- Quota accounting (Req 5.9) ------------------------------------------

  test "add_quota_exceeded? is false when the session sets no quota" do
    guest = build_guest
    guest.save!
    assert_nil @session.guest_add_quota
    assert_not guest.add_quota_exceeded?
  end

  test "add_quota_exceeded? becomes true once add_count reaches the session quota" do
    @session.update!(guest_add_quota: 2)
    guest = build_guest
    guest.save!

    assert_not guest.add_quota_exceeded?
    guest.record_add!
    assert_not guest.add_quota_exceeded?
    guest.record_add!
    assert guest.add_quota_exceeded?
  end

  test "record_add! increments the lifetime add_count and stamps the rate window" do
    guest = build_guest
    guest.save!
    assert_equal 0, guest.add_count

    now = Time.current
    guest.record_add!(now: now)
    guest.reload
    assert_equal 1, guest.add_count
    assert_in_delta now.to_f, guest.rate_window_started_at.to_f, 1.0
  end

  # --- Rate limiting (Req 5.9) ---------------------------------------------

  test "rate_limited? is false when the session sets no rate" do
    guest = build_guest
    guest.save!
    assert_not guest.rate_limited?
  end

  test "rate_limited? enforces minimum spacing between accepted additions" do
    @session.update!(guest_add_rate_per_minute: 30) # min 2s spacing
    guest = build_guest
    guest.save!

    start = Time.current
    guest.record_add!(now: start)

    assert guest.rate_limited?(now: start + 1.second),
      "a second add within the spacing window must be rate limited"
    assert_not guest.rate_limited?(now: start + 3.seconds),
      "an add after the spacing window must be allowed"
  end
end
