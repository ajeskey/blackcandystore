# frozen_string_literal: true

# Serves the same-origin remote-stream proxy path produced by
# `PathResolver#resolve_stream` for a Song that lives in a Remote_Library
# (`/stream/remote/:song_id`, Req 8.5).
#
# The redeeming server PROXIES the audio rather than handing the hosting URL to
# the browser: it fetches the bytes from the hosting server's federation stream
# endpoint through the Song's Library_Connection and forwards them to the
# player. This keeps the Access_Grant credential (`grant_token`) server-side —
# it is never exposed to the browser — and lets the redeeming server enforce its
# own 10s content timeout (Req 6.2, 6.3). From the player's perspective the
# stream is always same-origin, so the Web_Player and App_Player need no
# library-specific logic.
#
# This is a browser/app-facing endpoint, so it inherits the app's normal
# session/token authentication from ApplicationController; the grant token used
# to reach the hosting server is loaded server-side from the Library_Connection.
#
# NOTE: this is intentionally a top-level controller (not `Stream::Remote`)
# because `Stream` is already an application model class, so it cannot double as
# a controller namespace. The route still maps the `/stream/remote/:song_id`
# path that `PathResolver` emits.
class RemoteStreamController < ApplicationController
  include SidecarStreamAccess

  # Request headers forwarded up to the hosting server so HTTP range requests
  # (seeking/partial playback) keep working across the proxy (Req 6.2).
  FORWARDED_REQUEST_HEADERS = %w[Range If-Range].freeze

  # Response headers copied back from the hosting server so the player receives
  # correct range metadata. Content-Type and Content-Length are set by
  # `send_data` from the forwarded body, so they are not copied here.
  FORWARDED_RESPONSE_HEADERS = %w[Content-Range Accept-Ranges].freeze

  def show
    song = Song.find(params[:song_id])
    connection = remote_connection_for(song)

    # A Song that is not served from a resolvable Remote_Library (no remote
    # library, no connection, or a revoked/unavailable connection) cannot be
    # proxied; surface it as unavailable instead of attempting a call
    # (Req 6.3, 8.11).
    return render_unavailable if connection.nil? || !connection.active?

    client = Federation::Client.new(
      base_url: connection.server_base_url,
      grant_token: connection.grant_token
    )

    # Federation::Client applies the 10s CONTENT_TIMEOUT internally (Req 6.3)
    # and translates transport/HTTP failures into the domain exceptions rescued
    # below.
    remote_response = client.stream(
      connection.remote_library_id,
      remote_song_id(song),
      forwarded_request_headers
    )

    send_remote_response(remote_response)
  rescue Federation::Client::Unauthorized
    # The hosting server rejected the grant token (revoked/expired mid-use):
    # access to the Remote_Library is no longer available (Req 6.5, 6.7).
    render_unavailable
  rescue Federation::Client::Timeout, Federation::Client::Unreachable, Federation::Client::Error
    # The hosting server exceeded the 10s content budget, was unreachable, or
    # returned another error. The Library_Connection is retained unchanged
    # (Req 6.3).
    render_unavailable
  end

  private

  # The Library_Connection used to reach the hosting server for this Song, or
  # nil when the Song does not belong to a resolvable Remote_Library.
  def remote_connection_for(song)
    library = song.library
    return nil if library.nil? || !library.remote?

    library.library_connection
  end

  # The hosting server's id for this Mirrored_Song. Mirrored rows store the
  # hosting-side id in the `songs.remote_song_id` column at sync time, so the
  # proxy keys the federation stream endpoint on (library_id, remote_song_id)
  # rather than the local Song id (Req 7.1, 7.2). The mapping the controller's
  # original ASSUMPTION anticipated now exists, so this is the single point that
  # translates a local Mirrored_Song to its hosting-side id.
  def remote_song_id(song)
    song.remote_song_id
  end

  def forwarded_request_headers
    FORWARDED_REQUEST_HEADERS.each_with_object({}) do |name, headers|
      value = request.headers[name]
      headers[name] = value if value.present?
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
      disposition: "attachment",
      status: remote_response.code
    )
  end

  # Surface the Remote_Library as unavailable rather than failing opaquely
  # (Req 6.3, 6.7).
  def render_unavailable
    render json: {
      type: "RemoteLibraryUnavailable",
      message: "The remote library is currently unavailable."
    }, status: :service_unavailable
  end
end
