# frozen_string_literal: true

# Cast_Session holds the client-side `client_cast` playback state for a User
# (Req 17). Under the `client_cast` Playback_Mode the Web_Player/App_Player is
# the Cast_Client and the audio source: it fetches a Song's audio from its
# Resolved_Stream_Path and streams it directly to a single target Output_Device
# (Req 17.1-17.5). The Server never decodes or sends the cast Song's audio
# (audio-source invariant, Req 17.15) and manages the activity only through this
# Cast_Session, never through a Playback_Session (Req 18.2).
#
# This record is the lightweight server-side mirror of that client-side state,
# kept purely for bookkeeping (Req 18.2, 18.3). The actual casting/streaming to
# the device happens on the client. The state-transition methods below are pure
# in-memory mutations returning whether the transition was applied, so the same
# state machine can be exercised directly by unit tests and by Property 20; the
# controller is responsible for persisting an applied transition.
class CastSession < ApplicationRecord
  # Every Cast_Session is in exactly one of these states at all times
  # (state invariant, Req 17.14; Property 20).
  STATES = %w[stopped playing paused].freeze

  belongs_to :user

  validates :state, inclusion: { in: STATES }

  # Whether this Cast_Session currently manages an active `client_cast` playback
  # activity. A `stopped` session is idle and manages no activity; a `playing`
  # or `paused` session manages one. Used by PlaybackMode to enforce the
  # mode-exclusivity invariant (Property 21): only one session kind may be
  # active for a User at a time.
  def active?
    state != "stopped"
  end

  # Begin (or restart) casting the current Song to the target Output_Device and
  # move to `playing` (Req 17.5). A play with no target Output_Device is rejected
  # and leaves the state unchanged (Property 20): the client has nothing to cast
  # to, mirroring the Playback_Session contract of task 24.1.
  #
  # Optionally sets the Song being cast and the starting position. Returns true
  # when the transition was applied, false when it was rejected.
  def play(song_id: nil, position: nil)
    return false if target_output_device_id.blank?

    self.current_song_id = song_id unless song_id.nil?
    self.position = position unless position.nil?
    self.state = "playing"
    true
  end

  # Resume a paused Cast_Session, returning it to `playing` while retaining the
  # exact current Song and playback position captured at pause (Req 17.16;
  # Property 20 resume-after-pause transition). Deliberately does not touch
  # `current_song_id` or `position`. A resume with no target Output_Device is
  # rejected and leaves the state unchanged (Property 20).
  def resume
    return false if target_output_device_id.blank?

    self.state = "playing"
    true
  end

  # Pause a `playing` Cast_Session: the client stops streaming to the device but
  # the current Song and playback position are retained so a following resume can
  # continue exactly where it left off (Req 17.6). Pause is only defined from the
  # `playing` state; from any other state it is a no-op and returns false.
  def pause
    return false unless state == "playing"

    self.state = "paused"
    true
  end

  # Stop the Cast_Session: the client stops streaming and the playback position
  # is cleared (Req 17.7). Always applies, leaving the session in `stopped`.
  def stop
    self.position = 0
    self.state = "stopped"
    true
  end

  # The target Output_Device became unreachable. If it disconnects while the
  # session is `playing`, casting stops and the session moves to `stopped`
  # (Req 17.12; Property 20 "last active Output_Device unavailable during
  # playing -> stopped"). A Cast_Session casts to a single target device, so that
  # device is its only (and therefore last) active Output_Device. Unavailability
  # of a device that is not the current target, or while not playing, is a no-op.
  def output_device_unavailable(device_id)
    return false unless state == "playing" && device_id.to_i == target_output_device_id

    self.position = 0
    self.state = "stopped"
    true
  end
end
