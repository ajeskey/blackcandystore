# frozen_string_literal: true

# ResumeStreamsJob re-establishes the always-on broadcasts after a server
# restart (Req 10.4, 10.10). Rails is the source of truth: the Broadcaster holds
# no authoritative domain state, so on boot this job reads persisted
# Station_State/Session_State and tells the Broadcaster which broadcasts to spin
# back up (design: "Server restart resume").
#
# The RESUME DECISION — which persisted Radio_Stations and Co_Listen_Sessions
# are eligible to resume — is a pure, deterministic method (`resumable_broadcasts`)
# kept deliberately separate from any Broadcaster side effect so it can be
# property-tested in isolation (Property 26). The rule is:
#
# - Resume exactly the `started` Radio_Stations (Req 10.4).
# - Resume the `active` Co_Listen_Sessions whose Session_Duration has NOT
#   expired; a session whose duration has elapsed is treated as ended and is
#   never resumed (Req 12.4).
# - Honor the Admin-configurable concurrency cap (`max_concurrent_streams`):
#   resume at most that many broadcasts total across both kinds (Req 10.10). A
#   nil cap means unbounded.
#
# Broadcaster re-establishment (the control-API call) is wired in task 9.3:
# `#reestablish` asks the Broadcaster to spin each eligible broadcast back up
# with its first resolved source. The Broadcaster client and source resolver are
# injectable (defaulting to the real ones) so the resume path can be exercised
# with fakes, and the pure resume decision (`resumable_broadcasts`) is kept
# free of any Broadcaster I/O so Property 26 still tests it in isolation.
class ResumeStreamsJob < ApplicationJob
  # @param now [Time] reference time expiration is measured against
  # @param broadcaster [Broadcaster::Client] injectable control-client seam
  # @param source [BroadcastSource] injectable broadcast-argument resolver seam
  def perform(now: Time.current, broadcaster: Broadcaster.client, source: BroadcastSource.new)
    @broadcaster = broadcaster
    @source = source
    resumable_broadcasts(now: now).each { |broadcast| reestablish(broadcast) }
  end

  # The persisted broadcasts to re-establish on boot, in a deterministic order.
  #
  # Pure decision: it reads persisted state (and the concurrency cap setting) and
  # returns the eligible Radio_Stations and Co_Listen_Sessions. It never mutates
  # a record and never touches the Broadcaster, so the resume rule stays
  # property-testable in isolation (Property 26).
  #
  # Eligible broadcasts are ordered by `created_at` (oldest established first),
  # tie-broken by type and id for stability, then truncated to the concurrency
  # cap. When the number of eligible broadcasts exceeds the cap, the oldest ones
  # win the available capacity.
  #
  # @param now [Time] the reference time expiration is measured against
  #   (injectable for deterministic tests; defaults to the current time)
  # @return [Array<RadioStation, CoListenSession>] the broadcasts to resume
  def resumable_broadcasts(now: Time.current)
    eligible = eligible_stations + eligible_sessions(now: now)
    eligible.sort_by! { |broadcast| [ broadcast.created_at, broadcast.class.name, broadcast.id ] }

    cap = Setting.max_concurrent_streams
    return eligible if cap.nil?

    eligible.first([ cap.to_i, 0 ].max)
  end

  # Whether `session`'s Session_Duration has elapsed as of `now` (Req 12.4). A
  # bounded (hours/days) duration expires `created_at` + duration; a `perpetual`
  # duration never expires. Reuses ShareLinkService's Session_Duration → time
  # mapping so expiration is defined in exactly one place.
  #
  # @param session [CoListenSession]
  # @param now [Time]
  # @return [Boolean]
  def session_expired?(session, now: Time.current)
    expires_at = ShareLinkService.expires_at_for(
      kind: session.session_duration_kind,
      value: session.session_duration_value,
      created_at: session.created_at
    )

    expires_at.present? && expires_at <= now
  end

  private

  # Every `started` Radio_Station is eligible to resume (Req 10.4).
  def eligible_stations
    RadioStation.started.to_a
  end

  # Every `active` Co_Listen_Session whose duration has not expired is eligible;
  # expired ones are treated as ended and dropped (Req 10.10, 12.4).
  def eligible_sessions(now:)
    CoListenSession.active.reject { |session| session_expired?(session, now: now) }
  end

  # Re-establish `broadcast` on the Broadcaster via its control API (Req 10.4,
  # 10.10, 12.1): spin the broadcast back up under its stable broadcast id with
  # its first resolved source. Boot resume is best-effort — an unavailable
  # Broadcaster is tolerated so one unreachable broadcast never aborts resuming
  # the rest; the persisted Station_State/Session_State stays the source of
  # truth and a later resume run re-establishes anything still missing.
  def reestablish(broadcast)
    @broadcaster.start_broadcast(
      broadcast_id: @source.identifier(broadcast),
      kind: @source.kind(broadcast),
      source: @source.next_source(broadcast)
    )
  rescue Broadcaster::Unavailable
    nil
  end
end
