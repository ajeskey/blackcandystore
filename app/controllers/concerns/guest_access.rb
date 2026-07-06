# frozen_string_literal: true

# GuestAccess is the controller-side authentication + authorization concern for
# non-account Guests admitted to a Party_Session or Co_Listen_Session through a
# Share_Link. It is the request-layer counterpart to the pure
# `GuestAccessResolver` domain seam: this concern lifts the credential off the
# request and turns each rejection into an HTTP response, while every actual
# decision (identity binding, live-state gating, library scoping) is delegated
# to `GuestAccessResolver` so the rules live in exactly one place.
#
# It reuses the `Authentication` concern's Bearer path: a Guest presents its
# plaintext Guest_Token as a non-cookie `Authorization: Bearer <token>`
# credential (Req 9.2), which is resolved to the bound `Guest` by a keyed-digest
# lookup (`Guest.find_by_token`, via `GuestAccessResolver.resolve_guest`,
# Req 5.13). Guest_Tokens never satisfy the account login path — a Guest is not
# a `User` — so this concern is the only way a guest request is authorized.
#
# Controllers that serve guest requests include this concern and call:
#
#   * `require_guest!`          — as a `before_action`, to demand a live Guest.
#   * `authorize_guest_content!`— before reading/adding a Song or Library, to
#                                 apply existence-hiding library scoping.
#
# The rules, each delegated to `GuestAccessResolver`:
#
#   * **Identity** (Req 5.13): `current_guest` resolves the Bearer Guest_Token
#     to the single bound `Guest`, so quota and removal permissions always
#     attribute a request to one Guest.
#   * **Live-state gating** (Req 5.6, 5.8, 12.2): a resolved Guest is authorized
#     only while its session is active, unexpired, and the Guest has not been
#     removed; otherwise the request is rejected with an authorization error.
#   * **Library scoping with existence-hiding** (Req 5.3, 5.4, 5.5, 8.2, 8.6): a
#     Guest may read/add only content in the session's shared libraries; an
#     out-of-scope (or non-existent) target yields an identical not-found
#     response that never reveals whether the content exists.
module GuestAccess
  extend ActiveSupport::Concern

  included do
    helper_method :current_guest, :guest_signed_in?
  end

  private

  # The Guest bound to the presented non-cookie Bearer Guest_Token, or nil when
  # the request carries no token or the token matches no Guest (Req 5.13, 9.2).
  # Resolution is a keyed-digest lookup delegated to `GuestAccessResolver`, and
  # is memoized for the duration of the request (including a nil result, so a
  # tokenless request is not re-resolved on every call).
  def current_guest
    return @current_guest if defined?(@current_guest)

    @current_guest = resolve_current_guest
  end

  # The session (`PartySession`/`CoListenSession`) the current Guest was
  # admitted to, or nil when there is no current Guest.
  def current_guest_session
    current_guest&.sessionable
  end

  # Whether the request carries a Guest_Token that resolves to a Guest.
  def guest_signed_in?
    current_guest.present?
  end

  # Resolve the non-cookie Bearer Guest_Token to its bound Guest via keyed-digest
  # lookup (Req 5.13). Reuses the same Bearer extraction as the `Authentication`
  # concern; a blank or unmatched token yields nil.
  def resolve_current_guest
    authenticate_with_http_token do |token, _options|
      GuestAccessResolver.resolve_guest(token)
    end
  end

  # Demand a Guest whose access is still live. Rejects with an authentication
  # error when no Guest_Token resolves (no usable credential presented), and
  # with an authorization error once the session has ended or expired or the
  # Guest has been removed (Req 5.6, 5.8, 12.2). Suitable as a `before_action`
  # on guest-serving controllers.
  def require_guest!
    raise BlackCandy::Unauthorized if current_guest.nil?
    raise BlackCandy::Forbidden unless guest_access_valid?
  end

  # The live-state gate for the current Guest, delegated to
  # `GuestAccessResolver` (session active, unexpired, Guest not removed).
  # Rejects when there is no current Guest.
  def guest_access_valid?
    return false if current_guest.nil?

    GuestAccessResolver.access_valid?(session: current_guest_session, guest: current_guest)
  end

  # Authorize the current Guest to read or add content belonging to
  # `content_library_id`, scoped to the session's shared libraries (Req 5.3,
  # 8.2). When the target is outside the shared libraries — or does not exist at
  # all (a nil library id) — this raises `ActiveRecord::RecordNotFound`, which
  # renders the same not-found response for out-of-scope and non-existent
  # content and so never reveals whether the content exists (Req 5.4, 5.5, 8.6).
  def authorize_guest_content!(content_library_id)
    return if guest_content_accessible?(content_library_id)

    raise ActiveRecord::RecordNotFound
  end

  # Whether the current Guest may reach content in `content_library_id`,
  # delegated to `GuestAccessResolver`'s existence-hiding scope check. False
  # when there is no current Guest.
  def guest_content_accessible?(content_library_id)
    return false if current_guest_session.nil?

    GuestAccessResolver.content_accessible?(
      session: current_guest_session,
      content_library_id: content_library_id
    )
  end
end
