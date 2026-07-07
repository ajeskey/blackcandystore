# frozen_string_literal: true

# Songs::PlaybackPositionsController is the client-agnostic API_Surface for a
# single User's Playback_Position on a single Song (Req 6, 7, 8). It is a
# nested singular resource under a Song — the record is always for
# `Current.user`, so there is exactly one Playback_Position_Record per
# (User, Song) pair and no id is needed in the URL.
#
# Both actions answer `format.json` (the representation the Web_Player and an
# App_Player consume, Req 8.1, 8.2) AND `format.html`/`format.turbo_stream`,
# under IDENTICAL authorization (Req 8.3): authentication is enforced by the
# Authentication concern in ApplicationController before either action runs
# (Req 7.2, 7.6), and every read/write is scoped through
# `Current.user.playback_positions` so another User's record can never enter the
# relation (Req 7.3, 7.4). The OwnershipGuard before_action additionally rejects
# a targeted record whose owner cannot be resolved (Req 7.7).
#
#   * #show  — returns the authoritative Playback_Position_Record for
#     (Current.user, song) as `{ song_id, position_seconds, finished,
#     updated_at }`, or 404 when none exists (Req 6.2).
#   * #update — upsert. Rejects a non-resumable Song (Req 2.7) and an
#     out-of-range position (Req 2.6) with a 422 that leaves any existing record
#     unchanged; when a Client presents a timestamp older than the Server
#     record, the Server record wins and is left untouched (Req 6.5); otherwise
#     it stores the position and recomputes `finished` (Req 2.4, 2.5, 5.1, 5.4,
#     5.5).
class Songs::PlaybackPositionsController < ApplicationController
  include OwnershipGuard

  def show
    @playback_position = existing_playback_position

    if @playback_position
      respond_to do |format|
        format.json # renders show.json.jbuilder
        format.html { head :ok }
        format.turbo_stream { head :ok }
      end
    else
      respond_to do |format|
        format.json { head :not_found }
        format.html { head :not_found }
        format.turbo_stream { head :not_found }
      end
    end
  end

  def update
    @playback_position = existing_playback_position || Current.user.playback_positions.build(song: song)

    # Req 6.5: when the record already exists and a Client presents a timestamp
    # that is not newer than the Server record's, the Server record is the
    # source of truth and is left exactly as it is. When no Client timestamp is
    # presented there is nothing to reconcile against, so the save proceeds as a
    # normal last-write-wins upsert (Req 2.4, 2.5).
    unless keep_server_record?
      @playback_position.position_seconds = position_param
      # Req 5.1/5.4/5.5: the stored finished flag is recomputed from THIS save's
      # inputs — the Client's explicit signal OR the Server's remaining-time
      # backup — so a restart near the beginning clears a stale finished flag.
      @playback_position.finished = Playback::PositionPolicy.finished_after_save(
        position: @playback_position.position_seconds,
        duration: song.duration,
        client_finished: finished_param
      )
      # Req 2.6/2.7: the model validations reject an out-of-range position or a
      # non-resumable Song here; save! raises RecordInvalid (→ 422) without
      # persisting, so any pre-existing record is left unchanged.
      @playback_position.save!
    end

    respond_to do |format|
      format.json { render :show }
      format.html { head :ok }
      format.turbo_stream { head :ok }
    end
  end

  private

  # The parent Song from the nested route. `find` raises RecordNotFound (→ 404)
  # when the Song does not exist.
  def song
    @song ||= Song.find(params[:song_id])
  end

  # The existing Playback_Position_Record for (Current.user, song), or nil.
  # Scoped exclusively through `Current.user.playback_positions` so a record
  # owned by another User is structurally invisible (Req 7.3, 7.4). Memoized so
  # the OwnershipGuard before_action and the action share a single lookup.
  def existing_playback_position
    return @existing_playback_position if defined?(@existing_playback_position)

    @existing_playback_position = Current.user.playback_positions.find_by(song_id: params[:song_id])
  end

  # OwnershipGuard hook (Req 7.7): the record whose ownership must be verified
  # before a read/write. nil for a not-yet-existing record on upsert, which
  # makes the guard a no-op (there is nothing to read or modify yet).
  def ownership_guarded_record
    existing_playback_position
  end

  # Req 6.5: keep the Server-held record (skip the write) only when the record
  # already exists AND a Client timestamp is presented AND reconciliation
  # resolves in the Server's favor (the Server record is at least as recent).
  def keep_server_record?
    return false unless @playback_position.persisted?

    client_time = client_updated_at_param
    return false if client_time.nil?

    Playback::PositionReconciler.choose(
      server_updated_at: @playback_position.updated_at,
      client_updated_at: client_time
    ) == :server
  end

  def position_param
    playback_position_params[:position_seconds]
  end

  def finished_param
    ActiveModel::Type::Boolean.new.cast(playback_position_params[:finished])
  end

  # The Client-presented last-updated time, parsed leniently. A blank or
  # unparseable value is treated as "no timestamp presented" (nil), which lets
  # the upsert proceed as a normal last-write-wins save.
  def client_updated_at_param
    raw = playback_position_params[:client_updated_at]
    return nil if raw.blank?

    Time.zone.parse(raw.to_s)
  rescue ArgumentError
    nil
  end

  def playback_position_params
    params.require(:playback_position).permit(:position_seconds, :finished, :client_updated_at)
  end
end
