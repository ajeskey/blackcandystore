# frozen_string_literal: true

# Playback_Session holds the server-driven playback state for a User under the
# `server_playback` Playback_Mode (Req 14). The Server is the audio source for
# the session; the Web_Player and App_Player act only as a Remote_Control
# (Req 14.19). The Playback_Controller state machine (task 24.1) drives the
# transitions between the states; this model just persists the state.
class PlaybackSession < ApplicationRecord
  # Every Playback_Session is in exactly one of these states (state invariant,
  # Req 14.15).
  STATES = %w[stopped playing paused].freeze

  belongs_to :user

  # The set of Output_Devices currently receiving audio for this session
  # (Req 14.15). Serialized as an Array so a session can drive a multi-room
  # group of devices.
  serialize :active_output_device_ids, type: Array, coder: YAML

  validates :state, inclusion: { in: STATES }

  def active_output_device_ids
    super || []
  end

  # Whether this Playback_Session currently manages an active `server_playback`
  # activity. A `stopped` session is idle and manages no activity; a `playing`
  # or `paused` session manages one. Used by PlaybackMode to enforce the
  # mode-exclusivity invariant (Property 21): only one session kind may be
  # active for a User at a time.
  def active?
    state != "stopped"
  end
end
