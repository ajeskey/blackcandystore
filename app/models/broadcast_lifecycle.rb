# frozen_string_literal: true

# BroadcastLifecycle is the shared, pure decision core behind
# StationLifecycleService and SessionLifecycleService. Radio_Stations and
# Co_Listen_Sessions have distinct state vocabularies (`stopped`/`started` vs
# `active`/`ended`) but share three cross-cutting rules that Requirements 10 and
# 11 impose on both:
#
# - Mutation/lifecycle authority: only the owning User/Host or an Admin may drive
#   a start/stop/activate/deactivate transition (Req 10.3, 10.9; Property 4).
# - An Admin-configurable concurrency cap on the number of *live broadcasts*
#   (started stations + active co-listen sessions) enforced at start/activate
#   time (Req 10.5, 10.6, 10.7; Property 25).
# - A per-Shared_Stream Listener_Limit admission decision (Req 11.7; Property 11).
#
# Every method here is a pure decision: it reads state (and, for the cap, the
# live-broadcast count and the `max_concurrent_streams` setting) and returns a
# boolean. It never mutates a record and never touches the Broadcaster, so the
# lifecycle rules stay property-testable in isolation. The actual state
# transition + Broadcaster wiring lives in the two service objects that use this
# module (Broadcaster control is deferred to task 9.3).
module BroadcastLifecycle
  # The outcome of a lifecycle operation. `ok?` reports whether the transition
  # was applied; a rejected operation carries an `error` code and leaves the
  # subject's state unchanged. `subject` is always the (possibly unchanged)
  # Radio_Station or Co_Listen_Session. This mirrors PlaybackController::Result.
  Result = Struct.new(:ok, :error, :subject, keyword_init: true) do
    def ok?
      ok
    end

    def rejected?
      !ok
    end
  end

  # Rejection when the actor is neither the owner/Host nor an Admin (Req 10.3,
  # 10.9).
  ERROR_UNAUTHORIZED = :unauthorized

  # Rejection when starting/activating would exceed the concurrency cap
  # (Req 10.6). The subject's state is left unchanged.
  ERROR_AT_CAPACITY = :at_capacity

  # Rejection when the Broadcaster could not spin up / advance the broadcast
  # (Broadcaster::Unavailable, Req 12.1). Task 9.3 spins the broadcast up
  # *before* committing a start/activate transition, so this error always leaves
  # the subject in its prior (idle) state — there is never a "live in Rails but
  # not broadcasting" inconsistency to roll back.
  ERROR_BROADCASTER_UNAVAILABLE = :broadcaster_unavailable

  module_function

  # Mutation/lifecycle authority (Req 10.3, 10.9; Property 4). An operation is
  # permitted iff the actor is a full User account who either owns the subject
  # (`owner_id` is the subject's `user_id`) or is an Admin. Guests and anonymous
  # callers are never authorized: a Guest is not a User, so it fails the type
  # check regardless of any coincidental id overlap.
  def authorized?(actor, owner_id)
    return false unless actor.is_a?(User)

    actor.id == owner_id || actor.is_admin == true
  end

  # The number of currently live broadcasts: every `started` Radio_Station plus
  # every `active` Co_Listen_Session (Req 10.5). `excluding` drops the subject
  # under consideration from the count so a subject that is already live is not
  # counted against itself when re-evaluating capacity.
  def live_broadcast_count(excluding: nil)
    station_scope = RadioStation.started
    session_scope = CoListenSession.active

    if excluding.is_a?(RadioStation) && excluding.persisted?
      station_scope = station_scope.where.not(id: excluding.id)
    elsif excluding.is_a?(CoListenSession) && excluding.persisted?
      session_scope = session_scope.where.not(id: excluding.id)
    end

    station_scope.count + session_scope.count
  end

  # Whether another broadcast may be started/activated without exceeding the
  # Admin-configurable concurrency cap (Req 10.5, 10.6, 10.7; Property 25). A
  # nil `max_concurrent_streams` setting means unbounded, so capacity is always
  # available; otherwise capacity remains iff the live-broadcast count
  # (excluding the subject) is strictly below the cap.
  def capacity_available?(excluding: nil)
    cap = Setting.max_concurrent_streams
    return true if cap.nil?

    live_broadcast_count(excluding: excluding) < cap
  end

  # Listener_Limit admission decision (Req 11.7; Property 11). A new Listener is
  # admitted iff the current Listener count is strictly below the limit; a nil
  # limit means unbounded. This is a pure decision — it neither connects nor
  # accounts for the Listener, so refusing one leaves the existing Listener set
  # untouched.
  def listener_admissible?(current_listener_count:, listener_limit:)
    return true if listener_limit.nil?

    current_listener_count.to_i < listener_limit
  end
end
