# frozen_string_literal: true

# StreamEndpointController is the single, authenticated public surface for a
# Shared_Stream: it serves the standard MP3 Stream_Endpoint that the Web_Player
# and any generic Icecast/SHOUTcast client tune into (Req 3.1, 3.2, 3.3). It is
# the data-plane counterpart to the control-plane lifecycle services — Rails
# authorizes the connect once, then reverse-proxies the out-of-process
# Broadcaster's loopback fan-out from the *current* encode position (Req 2.4,
# 7.4, 7.6) so many Listeners share one continuous encode and the Broadcaster
# stays bound to loopback (see the design's Streaming / Broadcaster decision,
# option (a): reverse-proxy through Rails).
#
# Two actions back the two `member :stream` routes:
#   * `radio_station`      → GET /radio/:id/stream.mp3
#   * `co_listen_session`  → GET /co_listen_sessions/:id/stream.mp3
#
# A connect is admitted in the order the design's join sequence prescribes:
#
#   1. **Not broadcasting → 503** (Req 3.6, Property 8). The Stream_Endpoint URL
#      exists for every station/session regardless of state (Req 9.6), but a
#      request to a `stopped` station / `ended` session yields a
#      not-broadcasting response and no audio. Checked first (a
#      `prepend_before_action`, ahead of authentication) so a dormant stream
#      always reports "not broadcasting".
#   2. **Auth failure → 401** (Req 3.5). Connect-time authorization is delegated
#      to the `StreamAuthorization` concern, which overrides `require_login`:
#      a `public` station serves anyone (Req 3.7, 11.2); an `authenticated`
#      station requires a valid keyed-digest Stream_Token in the URL or an
#      authorized account credential (Req 11.3, 11.4); a co-listen stream
#      requires a live guest-derived token (Req 11.8, 11.9). Any other request
#      falls through to a 401.
#   3. **At capacity → 503** (Req 11.7, Property 11). The Listener_Limit is
#      enforced at connect against the Broadcaster's live listener count; a
#      Listener beyond the limit is refused without disrupting those already
#      connected.
#   4. Otherwise the Broadcaster's loopback fan-out is reverse-proxied to the
#      client as a continuous `audio/mpeg` stream (Req 3.2, 3.3, 7.4, 7.6).
#
# A Broadcaster that cannot be reached is surfaced as a 503 (translating
# `Broadcaster::Unavailable`) rather than leaking a transport error.
class StreamEndpointController < ApplicationController
  include StreamAuthorization

  # Generic MP3 clients request `.mp3`, a format the app-wide HTML/JSON error
  # negotiation does not cover, so surface the connect-time failures this
  # endpoint can raise as a format-agnostic JSON body with the right status.
  rescue_from BlackCandy::Unauthorized do |error|
    render_stream_error(error.type, error.message, :unauthorized)
  end

  rescue_from ActiveRecord::RecordNotFound do |error|
    render_stream_error("RecordNotFound", error.message, :not_found)
  end

  # Req 3.6 / Property 8: verify the broadcast is running before authenticating,
  # matching the design's join sequence (not-started takes precedence over an
  # auth failure).
  prepend_before_action :verify_broadcasting

  # GET /radio/:id/stream.mp3 — a Radio_Station's Stream_Endpoint.
  def radio_station
    serve_stream
  end

  # GET /co_listen_sessions/:id/stream.mp3 — a Co_Listen_Session's Stream_Endpoint.
  def co_listen_session
    serve_stream
  end

  private

  # Enforce the Listener_Limit, then hand the byte stream off to the Broadcaster
  # fan-out. A Broadcaster we cannot reach becomes a 503 (Req: translate
  # `Broadcaster::Unavailable`); a full stream becomes a capacity 503 (Req 11.7).
  def serve_stream
    case listener_admission
    when :unavailable then render_broadcaster_unavailable
    when :at_capacity then render_at_capacity
    else reverse_proxy_fan_out
    end
  end

  # The connect-time Listener_Limit decision (Req 11.7, Property 11): read the
  # broadcast's current listener count from the Broadcaster and defer the
  # admit/refuse decision to the pure lifecycle seam. Doubles as the
  # Broadcaster-reachability probe — a control failure here means we cannot
  # safely admit, so it is reported as `:unavailable` for a 503 rather than
  # streaming blindly.
  #
  # @return [Symbol] :ok, :at_capacity, or :unavailable
  def listener_admission
    status = broadcaster.status(broadcast_id)
    admissible = current_lifecycle.listener_admissible?(
      current_listener_count: status["listeners"].to_i
    )

    admissible ? :ok : :at_capacity
  rescue Broadcaster::Unavailable
    :unavailable
  end

  # Reverse-proxy the Broadcaster's loopback fan-out to the client as a
  # continuous `audio/mpeg` stream from the current encode position (Req 2.4,
  # 3.2, 3.3, 7.4, 7.6). The stream is closed in the ensure block so the
  # connection is always released; a fan-out that drops mid-stream is logged and
  # the (already-committed) response is closed.
  def reverse_proxy_fan_out
    # ActionController::Live is mixed in only on the streaming path (as the
    # transcoded-stream endpoint does) so the not-broadcasting / capacity /
    # unauthorized error renders stay ordinary buffered responses.
    self.class.send(:include, ActionController::Live)

    response.headers["Content-Type"] = "audio/mpeg"
    response.headers["Cache-Control"] = "no-cache, no-store"

    broadcaster.listen(broadcast_id) do |fragment|
      response.stream.write(fragment)
    end
  rescue Broadcaster::Unavailable => e
    # The fan-out failed after the reachability probe passed; nothing more can
    # be delivered on this connection. The stream is closed in `ensure`.
    Rails.logger.warn("Broadcaster fan-out unavailable for #{broadcast_id}: #{e.message}")
  ensure
    response.stream.close
  end

  # The Radio_Station or Co_Listen_Session being tuned into, resolved from the
  # route. `StreamAuthorization` reads this (via `stream_authorization_target`)
  # to authorize the connect, and the lifecycle/broadcast helpers key off it. A
  # missing id raises RecordNotFound → 404 (handled above).
  def current_target
    @current_target ||=
      case action_name
      when "radio_station" then RadioStation.find(params[:id])
      when "co_listen_session" then CoListenSession.find(params[:id])
      end
  end

  # The pure lifecycle seam for the resolved target, owning the
  # `audio_deliverable?` (Req 9.6/3.6) and `listener_admissible?` (Req 11.7)
  # decisions this endpoint depends on.
  def current_lifecycle
    @current_lifecycle ||=
      case current_target
      when RadioStation then StationLifecycleService.new(current_target)
      when CoListenSession then SessionLifecycleService.new(current_target)
      end
  end

  # The stable id the Broadcaster keys a broadcast by, matching the
  # `"<kind>:<id>"` convention of the Rails↔Broadcaster control contract.
  def broadcast_id
    @broadcast_id ||=
      case current_target
      when RadioStation then "radio_station:#{current_target.id}"
      when CoListenSession then "co_listen_session:#{current_target.id}"
      end
  end

  # `StreamAuthorization` hook: the target whose connect this request authorizes.
  def stream_authorization_target
    current_target
  end

  # The injectable Broadcaster control/fan-out client (loopback HTTP). Memoized
  # so a test can override it; defaults to the real client.
  def broadcaster
    @broadcaster ||= Broadcaster.client
  end

  # Req 3.6 / Property 8: audio is delivered only while the station is `started`
  # / the session is `active`; otherwise the endpoint reports not-broadcasting
  # and serves no audio.
  def verify_broadcasting
    render_not_broadcasting unless current_lifecycle.audio_deliverable?
  end

  def render_not_broadcasting
    render_stream_error(
      "NotBroadcasting",
      t("error.stream_not_broadcasting", default: "This stream is not currently broadcasting."),
      :service_unavailable
    )
  end

  def render_at_capacity
    render_stream_error(
      "AtCapacity",
      t("error.stream_at_capacity", default: "The maximum number of concurrent listeners has been reached."),
      :service_unavailable
    )
  end

  def render_broadcaster_unavailable
    render_stream_error(
      "BroadcasterUnavailable",
      t("error.broadcaster_unavailable", default: "The broadcast service is currently unavailable."),
      :service_unavailable
    )
  end

  # A format-agnostic JSON error body so a generic `.mp3` client receives a
  # meaningful status instead of tripping HTML/JSON content negotiation.
  def render_stream_error(type, message, status)
    render json: { type: type, message: message }, status: status
  end
end
