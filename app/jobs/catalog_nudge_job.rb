# frozen_string_literal: true

require "httparty"

# CatalogNudgeJob is the hosting-side sender for the best-effort Catalog_Nudge
# (Req 6.1, 6.3). It is enqueued by the `CatalogVersioning` bump hook after a
# local library's catalog change commits, and POSTs `{ nudge_token }` to every
# active Access_Grant that registered a `nudge_callback_url` at redemption so
# the redeemer can pull an Incremental_Sync immediately instead of waiting for
# its next scheduled poll.
#
# Delivery is fire-and-forget:
#   - a short open/read timeout keeps a slow or dead redeemer from stalling the
#     worker,
#   - transport failures (unreachable host behind NAT, timeout, DNS/TLS/socket
#     errors, non-2xx responses) are swallowed as a non-fatal miss so the job
#     never retries indefinitely and never rolls anything back — the Catalog and
#     the Access_Grant are left unchanged (Req 6.3).
#
# Correctness never depends on a nudge landing: the redeemer's scheduled pull
# reconciles regardless (Req 6.4). That is why every delivery failure is
# intentionally absorbed rather than surfaced or retried.
class CatalogNudgeJob < ApplicationJob
  queue_as :default

  # Short open/read timeout budget (seconds) for a single nudge POST. A redeemer
  # that does not accept the nudge quickly is simply missed.
  NUDGE_TIMEOUT = 5

  # Best-effort push nudge for `library_id`'s active grants. Each POST is
  # attempted independently so one unreachable redeemer does not prevent nudging
  # the others; every per-grant failure is a non-fatal miss.
  def perform(library_id)
    grants = AccessGrant.active
      .where(library_id: library_id)
      .where.not(nudge_callback_url: [ nil, "" ])

    grants.each { |grant| deliver_nudge(grant) }
  end

  private

  # Fire-and-forget POST of `{ nudge_token }` to the grant's callback URL. All
  # transport and HTTP failures are swallowed: a nudge is only an optimization,
  # so an unreachable redeemer (NAT), a timeout, or an error response is a
  # non-fatal miss that leaves the Catalog and Access_Grant unchanged (Req 6.3).
  def deliver_nudge(grant)
    HTTParty.post(
      grant.nudge_callback_url,
      headers: { "Content-Type" => "application/json" },
      body: { nudge_token: grant.nudge_token }.to_json,
      open_timeout: NUDGE_TIMEOUT,
      read_timeout: NUDGE_TIMEOUT
    )
  rescue Net::OpenTimeout, Net::ReadTimeout, ::Timeout::Error,
    SocketError, Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH,
    Errno::ENETUNREACH, OpenSSL::SSL::SSLError, HTTParty::Error, URI::InvalidURIError
    # Non-fatal miss (Req 6.3): the redeemer's scheduled pull reconciles anyway
    # (Req 6.4). Swallow so the job neither retries indefinitely nor changes any
    # state.
    nil
  end
end
