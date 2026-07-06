# frozen_string_literal: true

# CoListenSessionsController is the host-facing API_Surface for Co_Listen_Session
# management (Req 7.1, 9.1). Co-listen mode is the combination of Radio and
# Party: a shared, always-on collaborative Shared_Stream that participants add to
# while each listens on their own device.
#
# Every action responds to BOTH `format.html` (Turbo/Hotwire Web_UI) and
# `format.json` (a client-agnostic representation that does not depend on
# server-rendered HTML, Req 9.4). The same authorization is enforced regardless
# of response format (Req 9.5): create/modify/delete and the
# activate/deactivate lifecycle are permitted only for the owning Host or an
# Admin, delegated to the pure decision seams (AuthorizationPolicy /
# SessionLifecycleService) so HTML and JSON can never diverge. A request from a
# non-Host, non-Admin User is rejected with an authorization error (Req 10.9).
#
# The JSON representation exposes the Stream_Endpoint URL for every session
# regardless of its `active`/`ended` state (Req 9.6); audio is delivered at that
# endpoint only while the session is `active` (the StreamEndpointController that
# serves the audio is a separate concern — task 9.4). `audio_available` reflects
# the pure `SessionLifecycleService#audio_deliverable?` decision so a client can
# tell whether tuning in will currently yield audio.
class CoListenSessionsController < ApplicationController
  before_action :set_co_listen_session, only: [ :show, :edit, :update, :destroy, :activate, :deactivate, :generate_share_link ]
  before_action :authorize_mutation!, only: [ :show, :edit, :update, :destroy, :activate, :deactivate, :generate_share_link ]

  # List the Co_Listen_Sessions the current actor may manage: an Admin sees
  # every session, any other User sees only the sessions they host.
  def index
    @co_listen_sessions = accessible_sessions.order(created_at: :desc)

    respond_to do |format|
      format.html
      format.json { render json: @co_listen_sessions.map { |session| session_json(session) } }
    end
  end

  # Report a single Co_Listen_Session's client-agnostic state, including its
  # Stream_Endpoint URL regardless of state (Req 9.6).
  def show
    respond_to do |format|
      format.html
      format.json { render json: session_json(@co_listen_session) }
    end
  end

  # Render the new-session form (Web_UI).
  def new
    @co_listen_session = CoListenSession.new
  end

  # Create a Co_Listen_Session owned by the current User; it owns a
  # Shared_Playlist and produces a Shared_Stream (Req 7.1).
  def create
    @co_listen_session = CoListenSession.new(co_listen_session_params)
    @co_listen_session.user = Current.user
    @co_listen_session.save!

    respond_to do |format|
      format.html { redirect_to co_listen_session_path(@co_listen_session), notice: t("notice.created") }
      format.json { render json: session_json(@co_listen_session), status: :created }
    end
  end

  # Render the edit form (Web_UI).
  def edit
  end

  # Update a Co_Listen_Session's configuration (sharing, duration, guest caps,
  # listener limit). Owner/Admin only (Req 10.9).
  def update
    @co_listen_session.update!(co_listen_session_params)

    respond_to do |format|
      format.html { redirect_to co_listen_session_path(@co_listen_session), notice: t("notice.updated") }
      format.json { render json: session_json(@co_listen_session) }
    end
  end

  # Remove a Co_Listen_Session. It is deactivated first so its Shared_Stream is
  # ended before the configuration is removed. Owner/Admin only (Req 10.9).
  def destroy
    lifecycle.deactivate(actor: Current.user)
    @co_listen_session.destroy

    respond_to do |format|
      format.html { redirect_to co_listen_sessions_path, notice: t("notice.deleted") }
      format.json { head :no_content }
    end
  end

  # Activate the session's Shared_Stream (Req 10.7). The concurrency cap is
  # enforced by the lifecycle seam; exceeding it leaves the session inactive and
  # returns a capacity error (Req 10.6).
  def activate
    apply_lifecycle(lifecycle.activate(actor: Current.user))
  end

  # Deactivate / end the session's Shared_Stream (Req 10.8).
  def deactivate
    apply_lifecycle(lifecycle.deactivate(actor: Current.user))
  end

  # Generate the Share_Links that admit Guests to this session, one
  # Access_Grant-backed link per shared library (Req 4.2, 8.1). Owner/Admin
  # only. The plaintext token is available only in this response; only its keyed
  # digest is persisted (Req 8.7).
  def generate_share_link
    @share_links = ShareLinkService.generate(@co_listen_session)

    respond_to do |format|
      format.html { redirect_to co_listen_session_path(@co_listen_session), notice: t("notice.created") }
      format.json { render json: @share_links.map { |link| share_link_json(link) }, status: :created }
    end
  end

  private

  def set_co_listen_session
    @co_listen_session = CoListenSession.find(params[:id])
  end

  # The sessions the current actor may manage: all sessions for an Admin, only
  # the actor's own sessions otherwise.
  def accessible_sessions
    return CoListenSession.all if is_admin?

    CoListenSession.where(user: Current.user)
  end

  # Enforce mutation/lifecycle authority identically for HTML and JSON (Req 9.5,
  # 10.9; Property 4): only the owning Host or an Admin may proceed. Delegated to
  # the pure AuthorizationPolicy decision so the rule lives in one place.
  def authorize_mutation!
    raise BlackCandy::Forbidden unless AuthorizationPolicy.mutation_authorized?(Current.user, @co_listen_session.user_id)
  end

  def lifecycle
    @lifecycle ||= SessionLifecycleService.new(@co_listen_session)
  end

  # Translate a lifecycle Result into a response. An accepted transition renders
  # the updated session; a rejection leaves state unchanged and surfaces the
  # matching error: an unauthorized actor is a forbidden authorization error
  # (Req 10.9), exceeding the concurrency cap is a capacity error that keeps
  # the session inactive (Req 10.6), and an unreachable Broadcaster is a
  # service-unavailable error that likewise leaves the session's state unchanged
  # (the broadcast never started).
  def apply_lifecycle(result)
    return render_lifecycle_success if result.ok?

    case result.error
    when BroadcastLifecycle::ERROR_UNAUTHORIZED
      raise BlackCandy::Forbidden
    when BroadcastLifecycle::ERROR_AT_CAPACITY
      render_capacity_error
    when BroadcastLifecycle::ERROR_BROADCASTER_UNAVAILABLE
      render_broadcaster_unavailable
    else
      raise BlackCandy::Forbidden
    end
  end

  def render_lifecycle_success
    respond_to do |format|
      format.html { redirect_to co_listen_session_path(@co_listen_session), notice: t("notice.updated") }
      format.json { render json: session_json(@co_listen_session) }
    end
  end

  def render_capacity_error
    message = t("error.stream_at_capacity", default: "The maximum number of concurrent streams has been reached.")

    respond_to do |format|
      format.html { redirect_to co_listen_session_path(@co_listen_session), alert: message }
      format.json { render json: { type: "AtCapacity", message: message }, status: :service_unavailable }
    end
  end

  def render_broadcaster_unavailable
    message = t("error.broadcaster_unavailable", default: "The streaming service is currently unavailable.")

    respond_to do |format|
      format.html { redirect_to co_listen_session_path(@co_listen_session), alert: message }
      format.json { render json: { type: "BroadcasterUnavailable", message: message }, status: :service_unavailable }
    end
  end

  # Client-agnostic JSON representation of a Co_Listen_Session (Req 9.4). The
  # Stream_Endpoint URL is present regardless of state (Req 9.6); `audio_available`
  # reflects whether a request to that endpoint would currently deliver audio.
  def session_json(session)
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
      listener_limit: session.listener_limit,
      shared_library_ids: session.shared_library_ids,
      stream_endpoint_url: stream_endpoint_url_for(session),
      audio_available: SessionLifecycleService.new(session).audio_deliverable?,
      created_at: session.created_at,
      updated_at: session.updated_at
    }
  end

  def share_link_json(share_link)
    grant = share_link.access_grant

    {
      id: share_link.id,
      library_id: grant.library_id,
      token: grant.token,
      expires_at: grant.expires_at
    }
  end

  # The Stream_Endpoint URL for a session, exposed for every session regardless
  # of `active`/`ended` state (Req 9.6). The route/controller that serves the
  # audio bytes is wired separately (routes in task 8.6, the reverse-proxy
  # StreamEndpointController in task 9.4); this is the stable path clients tune
  # into once the session is active.
  def stream_endpoint_url_for(session)
    "/co_listen_sessions/#{session.id}/stream.mp3"
  end

  def co_listen_session_params
    params.require(:co_listen_session).permit(
      :session_duration_kind,
      :session_duration_value,
      :duplicate_policy,
      :max_guests,
      :guest_add_quota,
      :guest_add_rate_per_minute,
      :listener_limit,
      shared_library_ids: []
    )
  end
end
