# frozen_string_literal: true

# Party_Session is a Host-created listening session in which Guests add Songs to
# a Shared_Playlist and audio plays to Host-selected Output_Devices through the
# Playback_Sidecar (Req 4.1, 6.1). It is scoped to specific shared libraries
# (Req 4.7), time-boxed by a Session_Duration (Req 4.3), and revocable through
# its backing Share_Links (Req 4.6).
#
# All of the shared configuration — Session_State, Session_Duration, duplicate
# policy, per-Guest quota/rate caps, shared-library scoping, and the
# Shared_Playlist / Guests / Share_Links associations — lives in
# SharedSessionConcern, which a Party_Session and a Co_Listen_Session share.
# A Party_Session has no Stream_Endpoint and no listener limit because it plays
# to Output_Devices rather than to per-Listener streams (Req 9.7).
class PartySession < ApplicationRecord
  include SharedSessionConcern

  # The Host's selected Output_Devices — the speakers a Party_Session plays to
  # through the Playback_Sidecar (Req 6.1, 6.2). Selecting devices records a
  # `party_output_devices` join row per device; `output_devices` /
  # `output_device_ids` expose the current selection the PartyPlaybackDispatcher
  # fans audio out to, and `device_unavailable` removes one from the set so
  # playback continues on the rest (Req 6.4). Destroying the session clears its
  # selection (the Output_Device cache rows themselves are managed by
  # Device_Discovery and are left untouched).
  has_many :party_output_devices, dependent: :destroy
  has_many :output_devices, through: :party_output_devices
end
