# frozen_string_literal: true

require "test_helper"

# Property-based test for Property 14 of the radio-party-colisten feature.
#
# Design property (radio-party-colisten, Property 14):
#   For any Share_Link admission attempt, a Guest is admitted and issued a
#   Guest_Token iff the backing Access_Grant is `usable?` (active and not
#   expired) AND the session's current guest count is below `max_guests`;
#   otherwise admission is refused (authorization error for an unusable grant,
#   capacity response at the guest maximum) and no Guest record or token is
#   created.
#
#   Validates: Requirements 5.1, 5.11
#
# The decision lives in GuestAccessResolver: the pure predicates `admissible?`,
# `capacity_available?`, and `admission_denial_reason`, and the one writing
# method `admit`, which creates the admitted Guest and returns its plaintext
# Guest_Token exactly once. This test exercises the decision against every
# region of the input space by generating:
#   * the backing grant's state (active / revoked / expired), which fixes
#     `usable?`,
#   * `max_guests` (a positive cap or nil for unbounded), and
#   * the number of Guests already admitted to the session,
# so both refusal branches (`:unauthorized` for an unusable grant, `:at_capacity`
# at the guest maximum) and the admit branch are all covered.
#
# On every iteration it asserts the pure predicates agree with the expected
# decision, then runs `admit` and asserts that on success a Guest is persisted,
# a token is issued and bound to that new Guest, and the guest count grows by
# one; and on refusal the correct error is returned and NO Guest record or token
# is created (the count is unchanged).
class GuestAdmissionPropertyTest < ActiveSupport::TestCase
  # A readable directory so the freshly created local library backing the grant
  # passes media-path validation; the fixtures directory always exists.
  MEDIA_PATH = Rails.root.join("test", "fixtures", "files").to_s

  setup do
    @host = User.create!(email: "prop14-host-#{SecureRandom.uuid}@example.com", password: "foobar123")
    @library = Library.create!(name: "Prop14-#{SecureRandom.uuid}", kind: "local", media_path: MEDIA_PATH, owner: @host)
  end

  # Feature: radio-party-colisten, Property 14: Guest admission requires a usable grant and available capacity
  test "a guest is admitted and a bound token issued iff the backing grant is usable and the guest count is below max_guests, otherwise admission is refused with the right error and no guest or token is created" do
    check_property(iterations: 100) do
      # Which session model to exercise; both mix in SharedSessionConcern and so
      # share the guests/max_guests admission surface.
      klass_name = choose("PartySession", "CoListenSession")
      # The backing grant's state, which determines `usable?`.
      grant_state = choose(:active, :revoked, :expired)
      # A positive guest cap or nil (unbounded). Small values so the cap is
      # reached by the generated pre-existing guest count.
      max_guests = choose(nil, 1, 2, 3, 5)
      # Guests already admitted (and not removed) before this attempt.
      pre_existing = range(0, 6)

      [ klass_name, grant_state, max_guests, pre_existing ]
    end.check do |(klass_name, grant_state, max_guests, pre_existing)|
      reset_state

      session = klass_name.constantize.create!(user: @host, shared_library_ids: [], max_guests: max_guests)
      grant = build_grant(grant_state)
      seed_guests(session, pre_existing)

      grant_usable = (grant_state == :active)
      capacity = max_guests.nil? || pre_existing < max_guests
      expected_admissible = grant_usable && capacity
      expected_reason =
        if !grant_usable
          GuestAccessResolver::ERROR_UNAUTHORIZED
        elsif !capacity
          GuestAccessResolver::ERROR_AT_CAPACITY
        end

      ctx = "klass=#{klass_name} grant=#{grant_state} max=#{max_guests.inspect} pre=#{pre_existing}"

      # --- pure predicates ---------------------------------------------------
      assert_equal grant_usable, grant.usable?,
        "the built grant's usability must match the generated state (#{ctx})"
      assert_equal capacity,
        GuestAccessResolver.capacity_available?(current_guest_count: pre_existing, max_guests: max_guests),
        "capacity_available? must be true iff the guest count is below max_guests (#{ctx})"
      assert_equal expected_admissible,
        GuestAccessResolver.admissible?(grant_usable: grant_usable, current_guest_count: pre_existing, max_guests: max_guests),
        "admissible? must be true iff the grant is usable AND capacity is available (#{ctx})"
      actual_reason =
        GuestAccessResolver.admission_denial_reason(grant_usable: grant_usable, current_guest_count: pre_existing, max_guests: max_guests)
      if expected_reason.nil?
        assert_nil actual_reason, "admission_denial_reason must be nil when admissible (#{ctx})"
      else
        assert_equal expected_reason, actual_reason,
          "admission_denial_reason must report the refusal cause (#{ctx})"
      end

      # --- admit (the only writing method) ----------------------------------
      count_before = session.guests.where(removed_at: nil).count
      assert_equal pre_existing, count_before, "sanity: seeded guest count (#{ctx})"

      result = GuestAccessResolver.admit(session: session, grant: grant)
      count_after = session.guests.where(removed_at: nil).count

      if expected_admissible
        assert result.ok?, "admission must succeed when the grant is usable and capacity is available (#{ctx})"
        assert_nil result.error, "a successful admission carries no error (#{ctx})"

        assert result.guest.present? && result.guest.persisted?,
          "a successful admission must persist a Guest (#{ctx})"
        assert result.token.present?, "a successful admission must issue a Guest_Token (#{ctx})"

        # The issued token is bound to exactly the newly admitted Guest.
        assert_equal result.guest, GuestAccessResolver.resolve_guest(result.token, session: session),
          "the issued token must resolve to the newly admitted Guest (#{ctx})"
        assert_equal result.guest, Guest.find_by_token(result.token),
          "the issued token must be bound to the new Guest via its keyed digest (#{ctx})"

        assert_equal count_before + 1, count_after,
          "a successful admission must add exactly one Guest (#{ctx})"
      else
        assert result.denied?, "admission must be refused when the grant is unusable or the session is full (#{ctx})"
        assert_equal expected_reason, result.error,
          "an unusable grant refuses with :unauthorized; a full session with :at_capacity (#{ctx})"
        assert_nil result.guest, "a refused admission creates no Guest record (#{ctx})"
        assert_nil result.token, "a refused admission issues no token (#{ctx})"

        assert_equal count_before, count_after,
          "a refused admission must leave the guest count unchanged (no record created) (#{ctx})"
      end
    end
  end

  private

  # Wipe all guests, share links, sessions, and grants so each iteration starts
  # from a clean feature state. The host/library built in setup are reused.
  def reset_state
    Guest.delete_all
    ShareLink.delete_all
    PartySession.delete_all
    CoListenSession.delete_all
    AccessGrant.delete_all
  end

  # A backing AccessGrant in the requested state. `active` is usable; `revoked`
  # is unusable via status; `expired` is unusable via a past expiration.
  def build_grant(grant_state)
    status = grant_state == :revoked ? "revoked" : "active"
    expires_at = grant_state == :expired ? 1.day.ago : 7.days.from_now
    grant = AccessGrant.new(library: @library, status: status, expires_at: expires_at)
    grant.token = SecureRandom.urlsafe_base64(16)
    grant.save!
    grant
  end

  # Seed `count` already-admitted, not-removed Guests on the session so the
  # capacity accounting has a real pre-existing guest count to measure.
  def seed_guests(session, count)
    count.times do
      guest = session.guests.new(admitted_at: Time.current, add_count: 0)
      guest.token = SecureRandom.urlsafe_base64(16)
      guest.save!
    end
  end
end
