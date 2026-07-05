# frozen_string_literal: true

# Lets the playback sidecar fetch a Song's audio stream without a login session,
# authorized by a short-lived, song-scoped signed token (Req 14.9, 14.10).
#
# Under `server_playback` the Server is the audio source: PlaybackController
# hands the sidecar a `stream_url` (a same-origin stream path) plus a
# `stream_token`. The sidecar is an out-of-process, co-located companion with no
# browser cookie and no User session, so it cannot satisfy the normal
# Authentication concern. Rather than exposing the stream endpoints or handing
# the sidecar a long-lived credential, this concern accepts a Rails `signed_id`
# for the exact Song being fetched, namespaced to the `sidecar_stream` purpose
# and expiring after a short TTL (both set by PlaybackController). The token is
# HMAC-signed by the app's secret, is useless for any other Song or purpose, and
# leaves the normal session/token login path unchanged when absent.
#
# Security note: this is an additive, deliberately narrow authentication path.
# It authorizes ONLY read access to a single Song's stream, only for the life of
# the token, and only when the presented token verifies against that Song. A
# request without a valid token falls through to the standard `require_login`.
module SidecarStreamAccess
  extend ActiveSupport::Concern

  private

  # Override the Authentication concern's `require_login`: allow the request when
  # it carries a valid sidecar stream token for the requested Song, otherwise
  # defer to the normal login requirement.
  def require_login
    return if valid_sidecar_stream_token?

    super
  end

  # True when `params[:stream_token]` is a signed id that verifies to the Song
  # named by `params[:song_id]` under the `sidecar_stream` purpose and has not
  # expired.
  def valid_sidecar_stream_token?
    token = params[:stream_token]
    return false if token.blank?

    song = Song.find_signed(token, purpose: PlaybackController::SIDECAR_STREAM_PURPOSE)
    song.present? && song.id == params[:song_id].to_i
  end
end
