# frozen_string_literal: true

# Bookkeeping endpoint for a User's client-side Cast_Session under the
# `client_cast` Playback_Mode (Req 17, 18.2). The audio source is the client
# (Web_Player/App_Player); this controller only mirrors and drives the
# Cast_Session state machine (create/update the target Output_Device and current
# Song, then play/resume/pause/stop). The actual casting/streaming to the device
# happens on the client and is covered by client-side integration tests.
#
# The state-transition semantics live in the CastSession model so they stay
# pure and unit-/property-testable (Property 20). This controller finds or
# initializes the one-per-user session, applies a transition, and persists it
# only when the transition was accepted. A play/resume with no target
# Output_Device is rejected and the persisted state is left unchanged.
class CastSessionsController < ApplicationController
  before_action :set_cast_session

  # Report the current Cast_Session state for the User.
  def show
    render json: cast_session_json
  end

  # Create or update the bookkeeping record: select the target Output_Device to
  # cast to and, optionally, the current Song (Req 17.1, 17.2). Does not change
  # the cast state on its own.
  def create
    @cast_session.assign_attributes(session_attributes)
    @cast_session.save!

    render json: cast_session_json, status: :created
  end

  # Begin/restart casting the current Song and move to `playing` (Req 17.5).
  def play
    apply_transition { @cast_session.play(song_id: params[:current_song_id], position: params[:position]) }
  end

  # Resume a paused session to `playing`, retaining Song and position (Req 17.16).
  def resume
    apply_transition { @cast_session.resume }
  end

  # Pause a playing session, retaining Song and position (Req 17.6).
  def pause
    apply_transition { @cast_session.pause }
  end

  # Stop casting and clear the playback position (Req 17.7).
  def stop
    apply_transition { @cast_session.stop }
  end

  private

  def set_cast_session
    @cast_session = CastSession.find_or_initialize_by(user: Current.user)
  end

  # Applies a state-machine transition. When the transition is accepted the
  # updated session is persisted and returned; when it is rejected (e.g. a
  # play/resume with no target Output_Device) the persisted state is left
  # unchanged and an error is returned (Property 20).
  def apply_transition
    if yield
      @cast_session.save!
      render json: cast_session_json
    else
      render json: {
        type: "CastTransitionRejected",
        message: I18n.t("error.cast_transition_rejected", default: "Cast operation was rejected and the session state is unchanged.")
      }, status: :unprocessable_entity
    end
  end

  # Reads the bookkeeping attributes directly from the top-level params (only
  # the ones that were actually supplied), matching the convention used by the
  # other sharing/playback controllers and avoiding JSON parameter-wrapping
  # surprises.
  def session_attributes
    { current_song_id: params[:current_song_id], target_output_device_id: params[:target_output_device_id], position: params[:position] }
      .compact
  end

  def cast_session_json
    {
      state: @cast_session.state,
      current_song_id: @cast_session.current_song_id,
      target_output_device_id: @cast_session.target_output_device_id,
      position: @cast_session.position
    }
  end
end
