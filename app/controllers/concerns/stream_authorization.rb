# frozen_string_literal: true

# StreamAuthorization is the connect-time authorization concern for a
# Stream_Endpoint, layered exactly like `SidecarStreamAccess`: it overrides the
# `Authentication` concern's `require_login` so a request carrying a valid
# stream credential is admitted, and any other request falls through to the
# normal login requirement. It is the request-layer counterpart to the pure
# `StreamTokenService` decision seam — this concern lifts the credential and
# target off the request, and `StreamTokenService` owns the actual decision.
#
# A Stream_Endpoint serves a long-lived MP3 connection to generic Icecast /
# SHOUTcast-style clients that cannot send cookies or `Authorization` headers,
# so — like the sidecar's song-scoped signed token — authorization is validated
# once at connect from a `token` embedded in the URL (plus the standard session
# path when a browser is the client). The three authorization cases, all
# delegated to `StreamTokenService` (Property 9, Property 27):
#
#   1. **Public radio** (Req 3.7, 11.2): a `public` Stream_Visibility station
#      is served to any client with no credential.
#   2. **Authenticated radio** (Req 11.3, 11.4): the URL `token` validates
#      against the station's keyed-digest `StreamToken` (constant-time), OR the
#      request presents a session/Bearer credential for an account authorized to
#      the station. Rotating/revoking the token invalidates the URL (Req 11.5).
#   3. **Guest-scoped co-listen** (Req 11.8, 11.9): the URL `token` is a
#      purpose-scoped signed token derived from a participant's Guest_Token; it
#      authorizes only while that Guest's access is live and is never public.
#
# The including Stream_Endpoint controller resolves the station/session being
# tuned into by overriding `stream_authorization_target`; this concern defaults
# it to nil so a controller that has not wired a target denies every request
# rather than leaking audio.
module StreamAuthorization
  extend ActiveSupport::Concern

  private

  # Override the `Authentication` concern's `require_login`: admit the request
  # when it presents a valid connect-time stream credential for the resolved
  # target, otherwise defer to the normal login requirement (which then applies
  # the standard authenticated-account path).
  def require_login
    return if stream_connect_authorized?

    super
  end

  # The connect-time authorization decision for the resolved Stream_Endpoint
  # target, delegated to `StreamTokenService`. Returns false when no target is
  # resolved so an unwired endpoint never serves audio.
  def stream_connect_authorized?
    target = stream_authorization_target
    return false if target.nil?

    case target
    when RadioStation
      StreamTokenService.radio_stream_authorized?(
        radio_station: target,
        raw_token: stream_token_param,
        account_authorized: account_authorized_for_station?(target)
      )
    when CoListenSession
      StreamTokenService.colisten_stream_authorized?(
        session: target,
        raw_token: stream_token_param,
        session_expired: GuestAccessResolver.session_expired?(target)
      )
    else
      false
    end
  end

  # The Radio_Station or Co_Listen_Session being tuned into. The including
  # Stream_Endpoint controller overrides this to resolve the target from the
  # route; the nil default denies by construction.
  def stream_authorization_target
    nil
  end

  # The plaintext stream token carried in the Stream_Endpoint URL. A generic MP3
  # client passes it as a query param; nil when absent.
  def stream_token_param
    params[:token]
  end

  # Whether the current request carries a valid account credential authorized to
  # `station` (Req 11.4). The `Authentication` concern has already resolved any
  # session cookie / Bearer token into `Current` before this runs, so this only
  # applies the authorization rule: an Admin, the station's owner, or an account
  # that shares an authorized Library with the station's owner is authorized;
  # everyone else (including an anonymous connect) is not.
  def account_authorized_for_station?(station)
    user = Current.user
    return false if user.nil?
    return true if user.is_admin
    return true if station.user_id == user.id

    (Array(user.authorized_library_ids) & Array(station.user&.authorized_library_ids)).any?
  end
end
