# frozen_string_literal: true

# Serves the same-origin remote-asset proxy path produced by
# `PathResolver#resolve_asset` for a Mirrored_Album/Mirrored_Artist that lives in
# a Remote_Library (`/asset/remote/:type/:id`, Req 7.4).
#
# Like `RemoteStreamController` for audio, the redeeming server PROXIES the
# artwork bytes rather than storing them or handing the hosting URL to the
# browser: it loads the mirrored record, reads the hosting-side id it stored at
# sync time (`remote_album_id` / `remote_artist_id`), and fetches the image live
# from the hosting server's federation asset endpoint through the Library's
# Library_Connection. This keeps the Access_Grant credential (`grant_token`)
# server-side and means NO artwork bytes are ever stored on the redeeming server
# (Req 1.4). From the player/API perspective the artwork is always same-origin,
# so no library-specific logic is needed.
#
# This is a browser/app-facing endpoint, so it inherits the app's normal
# session/token authentication from ApplicationController; the grant token used
# to reach the hosting server is loaded server-side from the Library_Connection.
#
# The `:type` path segment is "albums" or "artists" (matching what
# `PathResolver#asset_record_type` emits and what the federation asset route
# expects); `:id` is the local mirrored record id.
class RemoteAssetController < ApplicationController
  # Response headers copied back from the hosting server. Content-Type and
  # Content-Length are set by `send_data` from the forwarded body, so they are
  # not copied here.
  FORWARDED_RESPONSE_HEADERS = %w[Cache-Control].freeze

  # The record types that map to a mirrored model, keyed by the `:type` path
  # segment `PathResolver#asset_record_type` produces (`record.class.name.tableize`).
  RECORD_TYPES = {
    "albums" => Album,
    "artists" => Artist
  }.freeze

  def show
    record_class = RECORD_TYPES[params[:type]]

    # An unrecognized type segment cannot be resolved to a mirrored record;
    # surface it as unavailable rather than raising.
    return render_unavailable if record_class.nil?

    record = record_class.find(params[:id])
    connection = remote_connection_for(record)

    # A record that is not served from a resolvable Remote_Library (no remote
    # library, no connection, or a revoked/unavailable connection) cannot be
    # proxied; surface it as unavailable instead of attempting a call
    # (Req 7.4, 9.8).
    return render_unavailable if connection.nil? || !connection.active?

    client = Federation::Client.new(
      base_url: connection.server_base_url,
      grant_token: connection.grant_token
    )

    # Federation::Client applies the 10s CONTENT_TIMEOUT internally (Req 6.3)
    # and translates transport/HTTP failures into the domain exceptions rescued
    # below. The stored hosting-side id (never the local id) references the
    # artwork on the hosting server (Req 7.4).
    remote_response = client.asset(
      connection.remote_library_id,
      params[:type],
      remote_record_id(record),
      variant: params[:variant]
    )

    send_remote_response(remote_response)
  rescue Federation::Client::Unauthorized
    # The hosting server rejected the grant token (revoked/expired mid-use):
    # access to the Remote_Library is no longer available (Req 6.5, 6.7).
    render_unavailable
  rescue Federation::Client::Timeout, Federation::Client::Unreachable, Federation::Client::Error
    # The hosting server exceeded the 10s content budget, was unreachable, or
    # returned another error. If the host is unavailable there is nothing to
    # fall back to — no artwork bytes are stored (Req 1.4, 7.4).
    render_unavailable
  end

  private

  # The Library_Connection used to reach the hosting server for this record, or
  # nil when the record does not belong to a resolvable Remote_Library.
  def remote_connection_for(record)
    library = record.library
    return nil if library.nil? || !library.remote?

    library.library_connection
  end

  # The hosting-side id stored on the mirrored record at sync time. This is the
  # single point of translation from the local mirrored id to the id the hosting
  # server's asset endpoint keys on (Req 7.4).
  def remote_record_id(record)
    case record
    when Album then record.remote_album_id
    when Artist then record.remote_artist_id
    end
  end

  def send_remote_response(remote_response)
    FORWARDED_RESPONSE_HEADERS.each do |name|
      value = remote_response.headers[name]
      response.headers[name] = value if value.present?
    end

    send_data(
      remote_response.body,
      type: remote_response.headers["Content-Type"].presence || "application/octet-stream",
      disposition: "inline",
      status: remote_response.code
    )
  end

  # Surface the Remote_Library as unavailable rather than failing opaquely
  # (Req 7.4, 9.8).
  def render_unavailable
    render json: {
      type: "RemoteLibraryUnavailable",
      message: "The remote library is currently unavailable."
    }, status: :service_unavailable
  end
end
