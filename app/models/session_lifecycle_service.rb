# frozen_string_literal: true

# SessionLifecycleService owns the Co_Listen_Session `Session_State` transitions
# (`active` <-> `ended`) and the rules that gate them (Req 10.7, 10.8). It is the
# session-side counterpart to StationLifecycleService and reuses the same pure
# decision core (BroadcastLifecycle) for authority, the concurrency cap, and the
# Listener_Limit admission decision, because a Co_Listen_Session Shared_Stream
# counts against the same broadcast budget as a Radio_Station (Req 10.5).
#
# It targets Co_Listen_Session specifically: a Party_Session shares the
# `active`/`ended` state vocabulary but plays to Output_Devices rather than
# producing a Shared_Stream, so it neither counts toward the concurrency cap nor
# exposes an audio-delivery/Listener_Limit decision (Req 9.7). Party teardown is
# handled separately (Requirement 12).
#
# As with the station service, the Broadcaster is wired here (task 9.3): activate
# spins up the Co_Listen_Session's Shared_Stream through the injectable
# Broadcaster control client and deactivate tears it down. The same consistency
# choice applies — the broadcast is spun up before the `active` transition is
# committed, so a Broadcaster::Unavailable leaves the session `ended` with no
# inconsistency to roll back, and deactivate is best-effort.
class SessionLifecycleService
  Result = BroadcastLifecycle::Result

  # @param session [CoListenSession] the session this service operates on
  # @param broadcaster [Broadcaster::Client] injectable control-client seam
  # @param source [BroadcastSource] injectable broadcast-argument resolver seam
  def initialize(session, broadcaster: Broadcaster.client, source: BroadcastSource.new)
    @session = session
    @broadcaster = broadcaster
    @source = source
  end

  attr_reader :session

  # Activate the session's Shared_Stream (Req 10.7). Rejected with
  # `:unauthorized` unless the actor is the Host or an Admin (Req 10.9;
  # Property 4). Activating an already-`active` session is an idempotent success
  # that does not re-check capacity or re-spin the broadcast. Otherwise the
  # Admin-configurable concurrency cap is enforced against the current
  # live-broadcast count (Req 10.5, 10.6, 10.7; Property 25): when the cap is
  # reached the request is rejected with `:at_capacity` and the session is left
  # inactive (`ended`). After the cap passes the Broadcaster is asked to spin up
  # the Shared_Stream with the first resolved source; if it is unavailable the
  # request is rejected with `:broadcaster_unavailable` and the session is left
  # `ended` (Req 12.1). Only once the broadcast is running does the session
  # transition to `active`.
  #
  # @param actor [User] the User attempting the transition
  # @return [Result]
  def activate(actor:)
    return failure(BroadcastLifecycle::ERROR_UNAUTHORIZED) unless authorized?(actor)
    return success if session.active?
    return failure(BroadcastLifecycle::ERROR_AT_CAPACITY) unless BroadcastLifecycle.capacity_available?(excluding: session)

    begin
      @broadcaster.start_broadcast(
        broadcast_id: @source.identifier(session),
        kind: @source.kind(session),
        source: @source.next_source(session)
      )
    rescue Broadcaster::Unavailable
      return failure(BroadcastLifecycle::ERROR_BROADCASTER_UNAVAILABLE)
    end

    session.update!(state: :active)
    success
  end

  # Deactivate / end the session's Shared_Stream (Req 10.8). Rejected with
  # `:unauthorized` unless the actor is the Host or an Admin (Req 10.9;
  # Property 4). Deactivating an already-`ended` session is an idempotent
  # success. On success the session transitions to `ended` and its Shared_Stream
  # is torn down on the Broadcaster (Req 12.1); the retained playlist and Guest
  # rejection are handled per Requirement 12. Teardown is best-effort: an
  # unavailable Broadcaster does not fail the deactivate.
  #
  # @param actor [User] the User attempting the transition
  # @return [Result]
  def deactivate(actor:)
    return failure(BroadcastLifecycle::ERROR_UNAUTHORIZED) unless authorized?(actor)

    session.update!(state: :ended) unless session.ended?
    tear_down_broadcast
    success
  end

  # Advance the running Shared_Stream to its next source, driven by a
  # ProgramSequencer decision over the Shared_Playlist (Req 7.8, 7.9). Resolves
  # the next source and hands it to the Broadcaster's `POST /next`. Rejected with
  # `:not_broadcasting` when the session is not `active`, and with
  # `:broadcaster_unavailable` when the control call cannot be delivered.
  #
  # @param history [Enumerable] recently played song ids, oldest first
  # @return [Result]
  def advance(history: [])
    return failure(:not_broadcasting) unless session.active?

    begin
      @broadcaster.next_source(
        @source.identifier(session),
        source: @source.next_source(session, history: history)
      )
    rescue Broadcaster::Unavailable
      return failure(BroadcastLifecycle::ERROR_BROADCASTER_UNAVAILABLE)
    end

    success
  end

  # Pure decision: audio is deliverable at the Stream_Endpoint iff the session
  # is `active` (Req 9.6, 3.6; Property 8). The endpoint URL exists regardless of
  # state; this decides only whether a request to it yields audio.
  def audio_deliverable?
    session.active?
  end

  # Pure Listener_Limit admission decision for this session's Shared_Stream
  # (Req 11.7; Property 11). A nil `listener_limit` means unbounded.
  #
  # @param current_listener_count [Integer]
  # @return [Boolean]
  def listener_admissible?(current_listener_count:)
    BroadcastLifecycle.listener_admissible?(
      current_listener_count: current_listener_count,
      listener_limit: session.listener_limit
    )
  end

  private

  # Best-effort Broadcaster teardown for deactivate (Req 12.1). An unavailable
  # Broadcaster is tolerated: the session is authoritatively `ended`.
  def tear_down_broadcast
    @broadcaster.stop_broadcast(@source.identifier(session))
  rescue Broadcaster::Unavailable
    nil
  end

  def authorized?(actor)
    BroadcastLifecycle.authorized?(actor, session.user_id)
  end

  def success
    Result.new(ok: true, error: nil, subject: session)
  end

  def failure(error)
    Result.new(ok: false, error: error, subject: session)
  end
end
