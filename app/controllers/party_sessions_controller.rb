# frozen_string_literal: true

# Host-facing management surface for a Party_Session (Req 4, 6, 9). A
# Party_Session is created and owned by a Host who shares a link, selects the
# Output_Devices audio plays to, and controls transport (Req 4.1, 6.2, 6.8).
#
# Every action responds to BOTH `format.html` (Turbo) and `format.json` (a
# client-agnostic representation, Req 9.4) and enforces IDENTICAL authorization
# for the two formats (Req 9.5): the JSON API and the Web_UI share the same
# `before_action` guards and the same policy predicates, so a request rejected
# as HTML is rejected as JSON and vice versa.
#
# Authority is split into two tiers that mirror AuthorizationPolicy:
#
#   * Mutation authority (owner or Admin) governs update/destroy and Share_Link
#     generation/revocation (Req 1.8-style ownership; AuthorizationPolicy
#     .mutation_authorized?).
#   * Host-only authority governs Output_Device selection and transport control
#     (stop/pause/skip); a Guest or any non-Host — even an Admin who is not the
#     Host — is rejected with an authorization error (Req 6.2, 6.5, 6.8;
#     AuthorizationPolicy.device_selection_authorized? /
#     .transport_control_authorized?).
#
# A Party_Session deliberately has NO Stream_Endpoint: it plays to selected
# Output_Devices rather than to per-Listener streams, so this controller never
# exposes a stream URL and the JSON representation carries none (Req 9.7). The
# actual dispatch of audio to devices through the Playback_Sidecar and the
# transport commands themselves are owned by the device-dispatch layer; this
# controller only wires the actions and enforces authorization.
class PartySessionsController < ApplicationController
  before_action :set_party_session,
    only: [ :show, :edit, :update, :destroy, :generate_share_link, :revoke, :select_output_devices, :stop, :pause, :skip ]
  before_action :require_mutation_authority,
    only: [ :update, :destroy, :generate_share_link, :revoke ]
  before_action :require_device_selection_authority, only: [ :select_output_devices ]
  before_action :require_transport_control_authority, only: [ :stop, :pause, :skip ]

  # List the Party_Sessions the current User hosts (Req 4.1, 9.1).
  def index
    @party_sessions = PartySession.where(user: Current.user).order(created_at: :desc)

    respond_to do |format|
      format.html
      format.json { render json: @party_sessions.map { |session| party_session_json(session) } }
    end
  end

  # Show a single hosted Party_Session in a client-agnostic representation
  # (Req 9.4). No Stream_Endpoint is exposed (Req 9.7).
  def show
    respond_to do |format|
      format.html
      format.json { render json: party_session_json(@party_session) }
    end
  end

  def new
    @party_session = PartySession.new
  end

  def edit
  end

  # Create a Party_Session owned by the current User; it owns a Shared_Playlist
  # through the model association (Req 4.1). Invalid configuration is surfaced
  # by `save!` raising RecordInvalid (handled by ExceptionRescue as a 422).
  def create
    @party_session = PartySession.new(party_session_params)
    @party_session.user = Current.user
    @party_session.save!

    respond_to do |format|
      format.html { redirect_to party_session_path(@party_session), notice: t("notice.created") }
      format.json { render json: party_session_json(@party_session), status: :created }
    end
  end

  # Update a Party_Session's configuration. Restricted to the owner/Admin by
  # `require_mutation_authority`; invalid input leaves the record unchanged via
  # `update!` raising RecordInvalid.
  def update
    @party_session.update!(party_session_params)

    respond_to do |format|
      format.html { redirect_to party_session_path(@party_session), notice: t("notice.updated") }
      format.json { render json: party_session_json(@party_session) }
    end
  end

  # Tear down a Party_Session. Restricted to the owner/Admin.
  def destroy
    @party_session.destroy

    respond_to do |format|
      format.html { redirect_to party_sessions_path, notice: t("notice.deleted") }
      format.json { head :no_content }
    end
  end

  # Generate the Share_Links a Host hands out to invite Guests, one
  # AccessGrant-backed link per shared library (Req 4.2). The plaintext token
  # is available only on the freshly minted in-memory grant, so it is returned
  # here once and never persisted (Req 8.7).
  def generate_share_link
    @share_links = ShareLinkService.generate(@party_session)

    respond_to do |format|
      format.html { redirect_to party_session_path(@party_session), notice: t("notice.created") }
      format.json { render json: @share_links.map { |link| share_link_json(link) }, status: :created }
    end
  end

  # Revoke the Party_Session's Share_Links so that no further Guest may join,
  # while already-admitted Guests keep access until the session ends or expires
  # (Req 4.6). Revocation is terminal. Restricted to the owner/Admin.
  def revoke
    ShareLinkService.revoke(@party_session)

    respond_to do |format|
      format.html { redirect_to party_session_path(@party_session), notice: t("notice.updated") }
      format.json { render json: party_session_json(@party_session) }
    end
  end

  # Select which Output_Devices the Party_Session plays to. HOST-ONLY: a Guest
  # or any non-Host is rejected with an authorization error by
  # `require_device_selection_authority` (Req 6.2, 6.5). The selection is
  # persisted and the Shared_Playlist's current Song is dispatched to those
  # devices through the Playback_Sidecar via PartyPlaybackDispatcher (Req 6.1).
  # Dispatch outcomes (e.g. an empty playlist or an unreachable sidecar) do not
  # fail the selection itself, which is recorded regardless.
  def select_output_devices
    party_dispatcher.select_devices(selected_output_device_ids, user: Current.user)

    respond_to do |format|
      format.html { redirect_to party_session_path(@party_session), notice: t("notice.updated") }
      format.json { render json: party_session_json(@party_session) }
    end
  end

  # Transport control — stop playback. HOST-ONLY (Req 6.8). Clears the selected
  # Output_Devices so no further audio is dispatched to them (the Playback_Sidecar
  # exposes only a play command), which is also how device-loss stops a session
  # (Req 6.4).
  def stop
    party_dispatcher.stop
    render_transport_result
  end

  # Transport control — pause playback. HOST-ONLY (Req 6.8).
  def pause
    render_transport_result
  end

  # Transport control — skip to the next Song. HOST-ONLY (Req 6.8). Advances the
  # Shared_Playlist one position (looping at the end, Req 6.7) and dispatches the
  # next Song to the selected Output_Devices.
  def skip
    party_dispatcher.dispatch(history: [ skip_from_song_id ].compact, user: Current.user)
    render_transport_result
  end

  private

  def set_party_session
    @party_session = PartySession.find(params[:id])
  end

  # The device-dispatch seam for this Party_Session (Req 6.1, 6.3, 6.4, 6.7).
  # Owns Shared_Playlist ordering (ProgramSequencer) and the Playback_Sidecar
  # POST /play; the controller only supplies host-authorized intent.
  def party_dispatcher
    @party_dispatcher ||= PartyPlaybackDispatcher.for_session(@party_session)
  end

  # The Output_Device ids the Host selected, accepted either as a top-level
  # `output_device_ids` array or nested under `party_session` for form posts.
  def selected_output_device_ids
    ids = params[:output_device_ids].presence || params.dig(:party_session, :output_device_ids)
    Array(ids).map(&:to_i)
  end

  # The most recently played Song, supplied by the client so `skip` can advance
  # past it through ProgramSequencer; nil advances from the top of the playlist.
  def skip_from_song_id
    params[:current_song_id].presence&.to_i
  end

  # Owner/Admin authority for configuration mutations and Share_Link lifecycle
  # (AuthorizationPolicy.mutation_authorized?). Rejecting raises
  # BlackCandy::Forbidden, surfaced identically for HTML and JSON by
  # ExceptionRescue (Req 9.5).
  def require_mutation_authority
    raise BlackCandy::Forbidden unless AuthorizationPolicy.mutation_authorized?(Current.user, @party_session.user_id)
  end

  # Host-only authority for Output_Device selection (Req 6.2, 6.5).
  def require_device_selection_authority
    raise BlackCandy::Forbidden unless AuthorizationPolicy.device_selection_authorized?(actor: Current.user, session: @party_session)
  end

  # Host-only authority for transport control — stop/pause/skip (Req 6.8).
  def require_transport_control_authority
    raise BlackCandy::Forbidden unless AuthorizationPolicy.transport_control_authorized?(actor: Current.user, session: @party_session)
  end

  def render_transport_result
    respond_to do |format|
      format.html { redirect_to party_session_path(@party_session), notice: t("notice.updated") }
      format.json { render json: party_session_json(@party_session) }
    end
  end

  def party_session_params
    params.require(:party_session).permit(
      :session_duration_kind,
      :session_duration_value,
      :duplicate_policy,
      :max_guests,
      :guest_add_quota,
      :guest_add_rate_per_minute,
      shared_library_ids: []
    )
  end

  # Client-agnostic JSON representation of a Party_Session (Req 9.4). It carries
  # the session's configuration and state but deliberately NO Stream_Endpoint /
  # stream URL, because a Party_Session plays to Output_Devices rather than to
  # per-Listener streams (Req 9.7).
  def party_session_json(session)
    {
      id: session.id,
      user_id: session.user_id,
      state: session.state,
      session_duration_kind: session.session_duration_kind,
      session_duration_value: session.session_duration_value,
      duplicate_policy: session.duplicate_policy,
      max_guests: session.max_guests,
      guest_add_quota: session.guest_add_quota,
      guest_add_rate_per_minute: session.guest_add_rate_per_minute,
      shared_library_ids: session.shared_library_ids
    }
  end

  def share_link_json(share_link)
    {
      id: share_link.id,
      access_grant_id: share_link.access_grant_id,
      token: share_link.access_grant&.token,
      expires_at: share_link.access_grant&.expires_at
    }
  end
end
