# frozen_string_literal: true

# Reads and updates the current User's Playback_Mode from either player
# (Req 16.2, 16.3). The same endpoint serves the Web_Player and the App_Player
# (JSON for the app/API, an HTML redirect for the browser), mirroring the
# SourcePreferencesController and CastSessionsController conventions.
#
# On update the requested mode is recorded through PlaybackMode.select, which
# defers to the User model's inclusion validation: a value other than
# `client_cast`/`server_playback` raises ActiveRecord::RecordInvalid, surfaced
# by ExceptionRescue as a 422 validation error, and the existing mode is left
# unchanged (Req 16.4). A successful change also enforces the mode-exclusivity
# invariant, tearing down the other mode's session so no activity is managed by
# both a Cast_Session and a Playback_Session (Req 18.1; Property 21).
class PlaybackModesController < ApplicationController
  def show
    render json: mode_json
  end

  def update
    Current.user.select_playback_mode(playback_mode_params[:playback_mode])

    respond_to do |format|
      format.json { render json: mode_json }
      format.html { redirect_back_or_to root_path, notice: t("notice.updated") }
    end
  end

  private

  def playback_mode_params
    params.permit(:playback_mode)
  end

  # Reports the selected mode together with the resolved audio source and the
  # session kind that manages the activity under that mode, so clients know
  # whether the client or the Server is the audio source (Req 16.6, 16.7).
  def mode_json
    {
      playback_mode: Current.user.playback_mode,
      audio_source: PlaybackMode.audio_source(Current.user),
      managed_by: PlaybackMode.manager(Current.user)
    }
  end
end
