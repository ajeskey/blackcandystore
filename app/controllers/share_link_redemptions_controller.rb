# frozen_string_literal: true

# ShareLinkRedemptionsController is the guest-join entry point of the
# API_Surface (Req 5.1, 9.1): opening a Share_Link admits a Guest to the
# Party_Session or Co_Listen_Session behind it and issues that Guest a
# Guest_Token (Req 5.1, 5.13).
#
# Joining is deliberately anonymous — the URL-embedded Share_Link token is the
# only credential a would-be Guest presents, and a Guest is not a `User` — so
# this controller skips the account login requirement (Req 9.2). Every actual
# decision is delegated to the pure seams so the rules live in one place:
#
#   * The presented token is resolved to its backing `AccessGrant` (keyed-digest
#     lookup, constant-time compare) and to the `ShareLink` it backs. A token
#     that matches no Share_Link yields an existence-hiding not-found, never
#     revealing whether a session exists (Req 5.4, 8.6).
#   * `GuestAccessResolver.admit` performs the admission decision + write: it
#     admits and issues a Guest_Token iff the backing grant is `usable?` (active
#     and not expired) AND the session has capacity below `max_guests`. A revoked
#     or expired grant is refused as an authorization error (Req 4.6, 8.5); a
#     full session is refused with a capacity response (Req 5.11); in either case
#     no Guest record or token is created.
#
# The freshly minted plaintext Guest_Token is returned to the client exactly
# once (only its keyed digest is persisted, Req 8.7); the API client then
# presents it as a non-cookie Bearer credential on subsequent guest requests
# (Req 9.2), which the `GuestAccess` concern resolves back to this Guest.
class ShareLinkRedemptionsController < ApplicationController
  # Opening a Share_Link needs no prior account session (Req 9.2); the token in
  # the URL is the credential and is validated in the action.
  skip_before_action :require_login

  # Show the join page for an opened Share_Link (Req 5.1, 9.2). Resolves the
  # token to its backing Share_Link and previews the session a Guest is about to
  # join WITHOUT admitting them or issuing a token — admission happens on the
  # POST. A token that matches no Share_Link yields an existence-hiding
  # not-found, never revealing whether a session exists (Req 5.4, 8.6). The
  # preview is deliberately minimal (no library contents) so an un-admitted
  # visitor learns nothing beyond what is needed to confirm and join.
  def show
    share_link = find_share_link!
    @session = share_link.sessionable
    @joinable = GuestAccessResolver.new_join_allowed?(share_link.access_grant)

    respond_to do |format|
      format.json
      format.html { redirect_back_or_to root_path }
    end
  end

  # Admit the Guest behind the opened Share_Link and issue a Guest_Token
  # (Req 5.1, 5.13). On refusal nothing is created: an unusable (revoked or
  # expired) grant is an authorization error (Req 4.6, 8.5) and a full session
  # is a capacity response (Req 5.11).
  def create
    share_link = find_share_link!
    @session = share_link.sessionable

    @admission = GuestAccessResolver.admit(
      session: @session,
      grant: share_link.access_grant,
      display_name: guest_display_name
    )

    return render_admission_denied(@admission) if @admission.denied?

    @guest = @admission.guest
    @guest_token = @admission.token
    expose_colisten_stream!

    respond_to do |format|
      format.json { render :create, status: :created }
      format.html do
        # Carry the freshly issued token to the guest client exactly once so it
        # can be presented as a Bearer credential on later requests; it is shown
        # once and never persisted anywhere retrievable (mirrors InvitesController).
        flash[:guest_token] = @guest_token
        # For a Co_Listen_Session, also carry the per-participant guest-derived
        # Stream_Token URL so the participant can tune into the Shared_Stream on
        # their own device (Req 7.4, 11.8, 11.9). Party_Sessions have no
        # Stream_Endpoint, so nothing is exposed for them (Req 9.7).
        flash[:stream_endpoint_url] = @stream_endpoint_url if @stream_endpoint_url
        redirect_back_or_to root_path, notice: t("notice.created")
      end
    end
  end

  private

  # Expose the per-participant, guest-derived Stream_Token so this participant
  # can connect to the Co_Listen_Session's Shared_Stream (Req 11.8, 11.9). The
  # token is a purpose-scoped signed id minted from the freshly admitted Guest
  # (`StreamTokenService.colisten_token_for`), inherently scoped to this session
  # and its shared Libraries and invalidated exactly when the Guest's access
  # ends. It is embedded in the Stream_Endpoint URL so a generic MP3 client that
  # cannot send cookies or Authorization headers can tune in (Req 7.4, 11.8).
  #
  # This is co-listen only: a Party_Session plays to Output_Devices and exposes
  # no Stream_Endpoint (Req 9.7), so neither a token nor a URL is minted for it.
  def expose_colisten_stream!
    return unless @session.is_a?(CoListenSession)

    @stream_token = StreamTokenService.colisten_token_for(@guest)
    @stream_endpoint_url = stream_co_listen_session_url(@session, format: :mp3, token: @stream_token)
  end

  # Resolve the opened Share_Link from the URL-embedded token. The plaintext
  # token is matched against the backing Access_Grant's keyed digest with a
  # constant-time compare (`AccessGrant.find_by_token`); a token that matches no
  # grant, or a grant that backs no Share_Link, raises `RecordNotFound` so an
  # invalid token is indistinguishable from a non-existent session (Req 5.4,
  # 8.6). Grant usability (revoked/expired) is decided later by admission.
  def find_share_link!
    grant = AccessGrant.find_by_token(params[:token])
    share_link = grant && ShareLink.find_by(access_grant_id: grant.id)
    raise ActiveRecord::RecordNotFound if share_link.nil?

    share_link
  end

  # The optional Guest_Display_Name used to attribute this Guest's additions
  # (Req 5.12); accepted either flat or nested under a `guest` key.
  def guest_display_name
    params[:display_name].presence || params.dig(:guest, :display_name).presence
  end

  # Translate an admission refusal into the matching HTTP response, identically
  # for HTML and JSON (Req 9.5): an unusable grant is an authorization error
  # (Req 4.6, 8.5) and a session already at `max_guests` is a capacity response
  # (Req 5.11). Neither creates a Guest or a token.
  def render_admission_denied(admission)
    raise BlackCandy::Forbidden if admission.error == GuestAccessResolver::ERROR_UNAUTHORIZED

    render_at_capacity
  end

  # A capacity response for a session that has reached its maximum number of
  # concurrent Guests (Req 5.11), mirroring the stream-capacity convention
  # (`:service_unavailable`) used by the lifecycle controllers.
  def render_at_capacity
    message = t("error.session_at_capacity", default: "This session has reached its maximum number of guests")

    respond_to do |format|
      format.json { render_json_error("AtCapacity", message, :service_unavailable) }
      format.html { redirect_back_or_to root_path, alert: message }
    end
  end
end
