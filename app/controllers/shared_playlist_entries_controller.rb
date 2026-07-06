# frozen_string_literal: true

# SharedPlaylistEntriesController is the Shared_Playlist contribution surface of
# the API_Surface (Req 5.2, 6.6, 9.1): the Host and admitted Guests add, remove,
# and reorder the individual Songs of a Party_Session or Co_Listen_Session
# Shared_Playlist. Every action responds to both `format.html` (the Turbo guest
# client, task 14.2) and `format.json` (a client-agnostic representation,
# Req 9.4) and applies IDENTICAL authorization to both (Req 9.5).
#
# The controller serves two kinds of actor over one surface:
#
#   * A **Host** authenticates through the normal account path (session cookie
#     or Bearer token) and may add, and remove/reorder ANY entry (Req 6.6).
#   * A **Guest** authenticates with its non-cookie Bearer Guest_Token, resolved
#     to the bound `Guest` by the `GuestAccess` concern (Req 5.13, 9.2). A Guest
#     may add Songs from the session's shared libraries (Req 5.2) and remove or
#     reorder ONLY entries it added (Req 6.6). `require_login` is overridden so a
#     live Guest is admitted; any other request falls through to the account
#     login requirement.
#
# Authority and enforcement are delegated to the pure seams so the rules live in
# one place: `SharedPlaylistAddService` enforces the per-Guest add quota/rate
# (rate-limit error, Req 5.9) and duplicate policy (Req 5.10) and records adder
# attribution (Req 5.12); `AuthorizationPolicy.entry_mutation_authorized?`
# decides remove/reorder authority (Req 6.6); and `GuestAccessResolver` scopes a
# Guest's reachable Songs to the shared libraries with existence-hiding
# not-found for out-of-scope or non-existent content (Req 5.3, 5.4, 8.6).
#
# Guests are limited to streaming and adding INDIVIDUAL Songs: this controller
# exposes no download, export, bulk-fetch, or file-path endpoint, and its entry
# representation carries no file path (Req 5.7).
class SharedPlaylistEntriesController < ApplicationController
  include GuestAccess

  # A rejected add never mutates the Shared_Playlist (Req 5.9, 5.10). Surface the
  # service's rejections consistently across formats: an exceeded per-Guest add
  # quota/rate is a rate-limit error (Req 5.9), and a refused duplicate is a
  # conflict (Req 5.10).
  rescue_from SharedPlaylistAddService::RateLimited do |error|
    render_contribution_error("RateLimited", error.message, :too_many_requests)
  end

  rescue_from SharedPlaylistAddService::DuplicateRejected do |error|
    render_contribution_error("DuplicateRejected", error.message, :conflict)
  end

  before_action :find_shared_playlist
  before_action :require_participant!
  before_action :find_entry, only: [ :update, :destroy ]

  # List the Shared_Playlist's entries in playlist order (Req 6.3). Readable by
  # the Host (including after teardown, Req 12.3) and by a live Guest of this
  # session; `require_participant!` has already established a permitted actor.
  def index
    @entries = @shared_playlist.entries

    respond_to do |format|
      format.html
      format.json
    end
  end

  # Add an individual Song to the Shared_Playlist (Req 5.2). The Song is scoped
  # to the session's shared libraries with an existence-hiding not-found for
  # out-of-scope or non-existent content (Req 5.3, 5.4, 8.6). The append is
  # delegated to `SharedPlaylistAddService`, which enforces the per-Guest add
  # quota/rate (Req 5.9) and duplicate policy (Req 5.10) before any write and
  # records adder attribution (Req 5.12).
  def create
    song = scoped_song!

    @entry = SharedPlaylistAddService.call(
      shared_playlist: @shared_playlist,
      song_id: song.id,
      guest: acting_guest,
      host: acting_host
    )

    # A Party_Session plays to Host-selected Output_Devices in Shared_Playlist
    # order, so an add re-dispatches the current order to those devices (Req 6.3).
    redispatch_party_playback

    respond_to do |format|
      format.json { render :show, status: :created }
      format.html { redirect_back_or_to root_path, notice: t("notice.created") }
      format.turbo_stream { render turbo_stream: stream_flash(message: t("notice.created")) }
    end
  end

  # Reorder an entry within the Shared_Playlist (Req 6.6). The Host may reorder
  # any entry; a Guest may reorder only entries it added. `insert_at` keeps
  # positions contiguous.
  def update
    authorize_entry_mutation!(@entry)
    @entry.insert_at(reorder_position) if reorder_position.present?

    # Reordering changes playback order for a Party_Session (Req 6.3, 6.6).
    redispatch_party_playback

    respond_to do |format|
      format.json { render :show }
      format.html { redirect_back_or_to root_path, notice: t("notice.updated") }
    end
  end

  # Remove an entry from the Shared_Playlist (Req 6.6). The Host may remove any
  # entry; a Guest may remove only entries it added, and a Guest attempting
  # another participant's entry is rejected with an authorization error.
  def destroy
    authorize_entry_mutation!(@entry)
    @entry.destroy!

    # A remove changes the Shared_Playlist a Party_Session plays (Req 6.3).
    redispatch_party_playback

    respond_to do |format|
      format.json { head :no_content }
      format.html { redirect_back_or_to root_path, notice: t("notice.deleted") }
    end
  end

  private

  # Allow a live Guest presenting a valid Guest_Token, otherwise defer to the
  # normal account login requirement (mirrors `SidecarStreamAccess`). A Guest is
  # not a `User`, so this is the only path that admits a guest request.
  def require_login
    return if guest_signed_in?

    super
  end

  def find_shared_playlist
    @shared_playlist = SharedPlaylist.find(params[:shared_playlist_id])
    @session = @shared_playlist.sessionable
  end

  # Re-dispatch a Party_Session's Shared_Playlist to its Host-selected
  # Output_Devices after the playlist changes, so the room hears the current
  # order (Req 6.3). No-op for a Co_Listen_Session (it fans out to per-listener
  # streams, not devices) and when no device is selected. Dispatch is
  # best-effort — a transient sidecar issue never fails the contribution, which
  # has already been persisted.
  def redispatch_party_playback
    return unless @session.is_a?(PartySession)
    return if @session.output_devices.empty?

    PartyPlaybackDispatcher.for_session(@session).dispatch
  end

  # Establish a permitted actor for the resolved session, identically for HTML
  # and JSON (Req 9.5). A Guest must be live (session active, unexpired, not
  # removed — Req 5.6, 5.8, 12.2) AND bound to THIS session, else the playlist is
  # hidden with a not-found so a Guest never learns about another session's
  # playlist (Req 5.4, 8.6). A non-Guest must be the Host of the session
  # (Req 6.2 kept host-scoped); any other account is rejected.
  def require_participant!
    if current_guest
      require_guest!
      raise ActiveRecord::RecordNotFound unless current_guest_session == @session
    else
      raise BlackCandy::Forbidden unless AuthorizationPolicy.host?(Current.user, @session)
    end
  end

  def find_entry
    @entry = @shared_playlist.entries.find(params[:id])
  end

  # The Song being added, scoped to the session's shared libraries. A Song that
  # does not exist or belongs to a Library the session does not share yields the
  # SAME not-found, so an out-of-scope target is indistinguishable from a missing
  # one (Req 5.3, 5.4, 8.6).
  def scoped_song!
    song = Song.find_by(id: add_song_id)

    unless GuestAccessResolver.content_accessible?(session: @session, content_library_id: song&.library_id)
      raise ActiveRecord::RecordNotFound
    end

    song
  end

  # Authorize a remove/reorder of `entry` (Req 6.6): permitted for the Host on
  # any entry, or the Guest that added that specific entry. Any other actor —
  # including a Guest targeting another participant's entry — is rejected with an
  # authorization error.
  def authorize_entry_mutation!(entry)
    return if AuthorizationPolicy.entry_mutation_authorized?(actor: current_actor, entry: entry, session: @session)

    raise BlackCandy::Forbidden
  end

  # The actor for the current request: the resolved Guest when a Guest_Token was
  # presented, otherwise the logged-in Host account.
  def current_actor
    current_guest || Current.user
  end

  # The adding Guest for an append, or nil for a Host add.
  def acting_guest
    current_guest
  end

  # The adding Host for an append, or nil for a Guest add. Mutually exclusive
  # with `acting_guest` as `SharedPlaylistAddService` requires.
  def acting_host
    current_guest ? nil : Current.user
  end

  def add_song_id
    params[:song_id].presence || params.dig(:shared_playlist_entry, :song_id).presence
  end

  def reorder_position
    (params[:position].presence || params.dig(:shared_playlist_entry, :position).presence)&.to_i
  end

  # Render a rejected contribution consistently across formats (Req 5.9, 5.10):
  # a JSON error body for API clients and a flash-based response for the Turbo
  # guest client. The Shared_Playlist is left unchanged by the service before
  # this runs.
  def render_contribution_error(type, message, status)
    respond_to do |format|
      format.json { render_json_error(type, message, status) }
      format.html { redirect_back_or_to root_path, alert: message }
      format.turbo_stream { render turbo_stream: stream_flash(type: :alert, message: message) }
    end
  end
end
