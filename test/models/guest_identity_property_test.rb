# frozen_string_literal: true

require "test_helper"

# Property-based test for the Guest identity seam of the radio-party-colisten
# feature (design Property 18).
#
# Property 18 governs *whose* request a bearer Guest_Token represents. Admission
# binds a freshly issued Guest_Token to exactly one Guest record (via its keyed
# digest), and that binding is the stable identity every later request is
# attributed to. So quota accounting (Property 19) and playlist-removal
# permissions (Property 22) always act on a single, unambiguous Guest.
#
# This exercises both resolution entry points named by the task:
#   * `Guest.find_by_token(raw_token)` — the keyed-digest lookup, and
#   * `GuestAccessResolver.resolve_guest(raw_token, session:)` — the same lookup
#     plus an optional token -> Guest -> session scope check.
#
# The invariants asserted for an arbitrary set of admitted Guests (spread across
# two sessions, each with a distinct token):
#   1. A presented token resolves to exactly one Guest — the Guest it was issued
#      to — through both entry points.
#   2. Distinct tokens resolve to distinct Guests (the binding is injective): no
#      two tokens ever collapse to the same Guest, and no token resolves to a
#      Guest other than its own (cross-token lookups miss).
#   3. An unknown, nil, or blank token resolves to no Guest.
#   4. Resolution is stable: the same token resolves to the same Guest every
#      time, so repeated requests are attributed to one Guest.
#   5. Session-scoped resolution honors the token -> Guest -> session binding: a
#      token resolves under its own session and never under a different one.
class GuestIdentityPropertyTest < ActiveSupport::TestCase
  setup do
    @seq = 0
  end

  # Feature: radio-party-colisten, Property 18: Guest identity is the token→Guest binding
  test "a presented Guest_Token resolves to exactly one Guest, distinct tokens resolve to distinct Guests, unknown/blank tokens resolve to none, and resolution is stable and session-scoped" do
    check_property(iterations: 100) do
      # A set of admitted guests, each assigned to one of the two sessions, and
      # the shape of the "no match" token to probe (unknown secret, nil, blank).
      n = range(2, 6)
      session_indices = Array.new(n) { choose(0, 1) }
      miss_kind = choose(:unknown, :nil, :blank)

      [ session_indices, miss_kind ]
    end.check do |(session_indices, miss_kind)|
      reset_dataset!
      host = build_host

      # Two sessions so token -> Guest -> session scoping is genuinely exercised
      # (a token bound to one session must not resolve under the other).
      sessions = [ PartySession.create!(user: host, shared_library_ids: []),
                   PartySession.create!(user: host, shared_library_ids: []) ]

      # Admit one Guest per spec, each bound to a distinct plaintext token.
      admitted = session_indices.map do |idx|
        session = sessions[idx]
        token = unique_token
        guest = session.guests.create!(display_name: "Guest-#{next_seq}", token: token)
        { guest: guest, token: token, session: session }
      end

      # (1) Each token resolves to exactly the Guest it was issued to, through
      # both entry points; and it resolves to a single record (not a set).
      admitted.each do |rec|
        by_lookup = Guest.find_by_token(rec[:token])
        by_resolver = GuestAccessResolver.resolve_guest(rec[:token])

        assert_equal rec[:guest], by_lookup,
          "Guest.find_by_token must resolve a token to the Guest it was issued to"
        assert_equal rec[:guest], by_resolver,
          "resolve_guest must resolve a token to the Guest it was issued to"
        assert_instance_of Guest, by_lookup,
          "a token must resolve to a single Guest record"
      end

      # (2) The binding is injective: distinct tokens resolve to distinct
      # Guests, so the resolved ids are all unique and cover every admitted
      # Guest exactly once.
      resolved_ids = admitted.map { |rec| Guest.find_by_token(rec[:token]).id }
      assert_equal resolved_ids.uniq.length, resolved_ids.length,
        "distinct tokens must resolve to distinct Guests (no two tokens share a Guest)"
      assert_equal admitted.map { |rec| rec[:guest].id }.sort, resolved_ids.sort,
        "the set of resolved Guests must be exactly the set of admitted Guests"

      # Cross-token lookups miss: presenting one Guest's token never resolves to
      # a different Guest.
      admitted.combination(2).each do |a, b|
        assert_not_equal b[:guest], Guest.find_by_token(a[:token]),
          "one Guest's token must never resolve to another Guest"
        assert_not_equal a[:guest], Guest.find_by_token(b[:token]),
          "one Guest's token must never resolve to another Guest"
      end

      # (3) An unknown, nil, or blank token resolves to no Guest through either
      # entry point. The unknown secret is guaranteed not to collide with any
      # issued token.
      miss_token =
        case miss_kind
        when :unknown then unique_token
        when :nil     then nil
        when :blank   then "   "
        end

      assert_nil Guest.find_by_token(miss_token),
        "an unknown/blank token must resolve to no Guest (find_by_token)"
      assert_nil GuestAccessResolver.resolve_guest(miss_token),
        "an unknown/blank token must resolve to no Guest (resolve_guest)"

      # (4) Resolution is stable: the same token resolves to the same Guest on
      # repeated requests, so quota/removal always attribute to one Guest.
      admitted.each do |rec|
        first = Guest.find_by_token(rec[:token])
        second = Guest.find_by_token(rec[:token])
        assert_equal first, second,
          "repeated resolution of the same token must yield the same Guest"
        assert_equal first, GuestAccessResolver.resolve_guest(rec[:token]),
          "both entry points must agree on the same token -> Guest binding"
      end

      # (5) Session-scoped resolution honors token -> Guest -> session: a token
      # resolves under its own session and never under the other one.
      admitted.each do |rec|
        own = rec[:session]
        other = sessions.find { |s| s != own }

        assert_equal rec[:guest], GuestAccessResolver.resolve_guest(rec[:token], session: own),
          "a token must resolve to its Guest when scoped to that Guest's session"
        assert_nil GuestAccessResolver.resolve_guest(rec[:token], session: other),
          "a token must not resolve when scoped to a session the Guest does not belong to"
      end
    end
  end

  private

  def next_seq
    @seq += 1
  end

  # Wipe every session/guest built by prior iterations so each iteration
  # observes only the records it creates.
  def reset_dataset!
    Guest.delete_all
    PartySession.delete_all
  end

  # A fresh Host user for the sessions under test.
  def build_host
    User.create!(email: "guest-identity-host-#{SecureRandom.uuid}@example.com", password: "foobar123")
  end

  # A plaintext Guest_Token guaranteed distinct from every other issued in this
  # iteration (SecureRandom entropy plus a monotonic suffix).
  def unique_token
    "guest-token-#{next_seq}-#{SecureRandom.urlsafe_base64(24)}"
  end
end
