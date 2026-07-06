# frozen_string_literal: true

# StationLifecycleService owns the Radio_Station `Station_State` transitions
# (`stopped` <-> `started`) and the rules that gate them (Req 10.1, 10.2). Like
# PlaybackController it is a pure, deterministic seam: given a Radio_Station and
# an actor it decides whether a start/stop is permitted, enforces the
# concurrency cap, applies the state transition, and returns a Result. It also
# exposes the two pure decisions the Stream_Endpoint depends on —
# `audio_deliverable?` (Req 9.6, Property 8) and `listener_admissible?`
# (Req 11.7, Property 11).
#
# Broadcaster wiring (task 9.3): on start this service spins up the
# out-of-process broadcast through the injectable Broadcaster control client
# (mirroring how PlaybackController takes an injectable sidecar client), and on
# stop it tears the broadcast down. The pure decisions (`audio_deliverable?`,
# `listener_admissible?`) and the concurrency cap stay untouched so the
# lifecycle/concurrency properties still hold; only the I/O seam is added.
#
# Consistency choice (documented per the task): the broadcast is spun up
# *before* the `started` transition is committed. A Broadcaster::Unavailable
# failure therefore returns a `:broadcaster_unavailable` Result while leaving the
# station `stopped` — there is no "started in Rails but not broadcasting"
# inconsistency to roll back. Stop is best-effort: the station is authoritatively
# `stopped` regardless of whether the Broadcaster teardown call reaches it.
class StationLifecycleService
  Result = BroadcastLifecycle::Result

  # @param station [RadioStation] the station this service operates on
  # @param broadcaster [Broadcaster::Client] injectable control-client seam
  # @param source [BroadcastSource] injectable broadcast-argument resolver seam
  def initialize(station, broadcaster: Broadcaster.client, source: BroadcastSource.new)
    @station = station
    @broadcaster = broadcaster
    @source = source
  end

  attr_reader :station

  # Start broadcasting (Req 10.1, 2.1). Rejected with `:unauthorized` unless the
  # actor is the owning User or an Admin (Req 10.3; Property 4). Starting an
  # already-`started` station is an idempotent success that does not re-check
  # capacity or re-spin the broadcast. Otherwise the Admin-configurable
  # concurrency cap is enforced against the current live-broadcast count
  # (Req 10.5, 10.6; Property 25): when the cap is reached the request is
  # rejected with `:at_capacity` and the station is left `stopped`. After the cap
  # passes the Broadcaster is asked to spin up the broadcast with the first
  # resolved source (Req 2.2); if it is unavailable the request is rejected with
  # `:broadcaster_unavailable` and the station is left `stopped` (Req 12.1). Only
  # once the broadcast is running does the station transition to `started`.
  #
  # @param actor [User] the User attempting the transition
  # @return [Result]
  def start(actor:)
    return failure(BroadcastLifecycle::ERROR_UNAUTHORIZED) unless authorized?(actor)
    return success if station.started?
    return failure(BroadcastLifecycle::ERROR_AT_CAPACITY) unless BroadcastLifecycle.capacity_available?(excluding: station)

    begin
      @broadcaster.start_broadcast(
        broadcast_id: @source.identifier(station),
        kind: @source.kind(station),
        source: @source.next_source(station)
      )
    rescue Broadcaster::Unavailable
      return failure(BroadcastLifecycle::ERROR_BROADCASTER_UNAVAILABLE)
    end

    station.update!(state: :started)
    success
  end

  # Stop broadcasting (Req 10.2). Rejected with `:unauthorized` unless the actor
  # is the owning User or an Admin (Req 10.3; Property 4). Stopping an
  # already-`stopped` station is an idempotent success. On success the station
  # transitions to `stopped` and its Shared_Stream is torn down on the
  # Broadcaster (Req 12.1). Teardown is best-effort: a Broadcaster that is
  # unavailable does not fail the stop, because the station is authoritatively
  # `stopped` and will not be re-established while stopped.
  #
  # @param actor [User] the User attempting the transition
  # @return [Result]
  def stop(actor:)
    return failure(BroadcastLifecycle::ERROR_UNAUTHORIZED) unless authorized?(actor)

    station.update!(state: :stopped) unless station.stopped?
    tear_down_broadcast
    success
  end

  # Advance the running broadcast to its next source, driven by a
  # ProgramSequencer decision (Req 2.2, 2.3, 2.5). Resolves the next source
  # (song path + signed stream token, or a continuity directive) and hands it to
  # the Broadcaster's `POST /next`. Rejected with `:not_broadcasting` when the
  # station is not `started`, and with `:broadcaster_unavailable` when the
  # control call cannot be delivered.
  #
  # @param history [Enumerable] recently played song ids, oldest first
  # @return [Result]
  def advance(history: [])
    return failure(:not_broadcasting) unless station.started?

    begin
      @broadcaster.next_source(
        @source.identifier(station),
        source: @source.next_source(station, history: history)
      )
    rescue Broadcaster::Unavailable
      return failure(BroadcastLifecycle::ERROR_BROADCASTER_UNAVAILABLE)
    end

    success
  end

  # Pure decision: audio is deliverable at the Stream_Endpoint iff the station
  # is `started` (Req 9.6, 3.6; Property 8). The endpoint URL exists regardless
  # of state; this decides only whether a request to it yields audio.
  def audio_deliverable?
    station.started?
  end

  # Pure Listener_Limit admission decision for this station's Shared_Stream
  # (Req 11.7; Property 11). A nil `listener_limit` means unbounded.
  #
  # @param current_listener_count [Integer]
  # @return [Boolean]
  def listener_admissible?(current_listener_count:)
    BroadcastLifecycle.listener_admissible?(
      current_listener_count: current_listener_count,
      listener_limit: station.listener_limit
    )
  end

  private

  # Best-effort Broadcaster teardown for stop (Req 12.1). An unavailable
  # Broadcaster is tolerated: the station is authoritatively `stopped`.
  def tear_down_broadcast
    @broadcaster.stop_broadcast(@source.identifier(station))
  rescue Broadcaster::Unavailable
    nil
  end

  def authorized?(actor)
    BroadcastLifecycle.authorized?(actor, station.user_id)
  end

  def success
    Result.new(ok: true, error: nil, subject: station)
  end

  def failure(error)
    Result.new(ok: false, error: error, subject: station)
  end
end
