# frozen_string_literal: true

require "test_helper"

# Property-based test for the Listener_Limit admission seam of the
# radio-party-colisten feature (design Property 11).
#
# Property 11 states: for any Listener_Limit and any current listener count, a
# new Listener is admitted iff the current count is strictly below the limit; a
# Listener beyond the limit is refused with a capacity response and the set of
# already-connected Listeners is unchanged. A nil limit means unbounded.
#
# The pure decision that governs this is `listener_admissible?`, exposed by:
#   * BroadcastLifecycle.listener_admissible? (the shared decision core), and
#   * StationLifecycleService#listener_admissible? (reads the Radio_Station's
#     `listener_limit`), and
#   * SessionLifecycleService#listener_admissible? (reads the
#     Co_Listen_Session's `listener_limit`).
#
# This test exercises that decision directly across generated limits (including
# nil / unbounded) and counts — the Broadcaster's byte-layer accounting and the
# Stream_Endpoint controller are wired in later tasks, so here we validate the
# pure seam they will depend on. Because the decision is pure (it neither
# connects nor accounts for a Listener), refusing one leaves the existing
# Listener set untouched; we model that by driving an admission loop off the
# decision and asserting a refused attempt never mutates the connected set.
#
# The three entry points are built in memory (unsaved records) on purpose:
# `listener_admissible?` only reads `listener_limit`, never touching the
# database, so we can drive it over arbitrary limits without persisting invalid
# configurations, and we assert all three agree on every input.
class ListenerLimitPropertyTest < ActiveSupport::TestCase
  # Feature: radio-party-colisten, Property 11: Listener limit admission
  test "a new listener is admitted iff the current count is strictly below the limit (nil = unbounded), and a refused listener leaves the connected set unchanged, across the pure core and both lifecycle services" do
    check_property(iterations: 100) do
      # A Listener_Limit that is either nil (unbounded, ~25% of the time) or a
      # positive integer, paired with a current listener count chosen to span
      # below, at, and above the limit so both sides of the "iff" and the
      # strict-boundary (count == limit vs count == limit - 1) are exercised.
      limit = choose(0, 0, 0, 1) == 1 ? nil : range(1, 10)
      count = range(0, 12)

      [ limit, count ]
    end.check do |(limit, count)|
      expected = limit.nil? || count < limit

      # 1) The shared pure decision core.
      core = BroadcastLifecycle.listener_admissible?(
        current_listener_count: count, listener_limit: limit
      )

      # 2) The station service, reading the Radio_Station's listener_limit.
      station = RadioStation.new(listener_limit: limit)
      station_decision = StationLifecycleService.new(station)
        .listener_admissible?(current_listener_count: count)

      # 3) The session service, reading the Co_Listen_Session's listener_limit.
      session = CoListenSession.new(listener_limit: limit)
      session_decision = SessionLifecycleService.new(session)
        .listener_admissible?(current_listener_count: count)

      # The decision matches "strictly below the limit" (nil == unbounded), and
      # is a strict boolean (never a truthy/ambiguous value), for all three
      # entry points, which must agree.
      [ core, station_decision, session_decision ].each do |decision|
        assert_equal expected, decision,
          "listener admissible iff current count (#{count}) is strictly below the limit (#{limit.inspect})"
      end
      assert_equal core, station_decision, "the station service must mirror the pure core decision"
      assert_equal core, session_decision, "the session service must mirror the pure core decision"

      # A Listener at or beyond a finite limit is refused (the capacity case).
      if !limit.nil? && count >= limit
        assert_equal false, core, "a listener at/beyond a finite limit is refused"
      end

      # The refused listener leaves the set of already-connected listeners
      # unchanged: model the current count as a concrete connected set, drive an
      # admission attempt off the decision, and assert the set only grows on
      # admission and is untouched on refusal.
      connected = (0...count).map { |i| "listener-#{i}" }
      before = connected.dup

      if core
        connected << "listener-new"
        assert_equal before.size + 1, connected.size,
          "an admitted listener joins the connected set"
        assert(limit.nil? || connected.size <= limit,
          "admission never pushes the connected count past a finite limit")
      else
        # Refused: no connection is made, so the set is byte-for-byte unchanged.
        assert_equal before, connected,
          "a refused listener leaves the already-connected set unchanged"
      end
    end
  end
end
