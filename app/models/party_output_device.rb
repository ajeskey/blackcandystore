# frozen_string_literal: true

# Party_Output_Device records that a Host has selected a specific Output_Device
# as a playback target for a Party_Session (Req 6.1, 6.2). It is the join between
# a Party_Session and the AirPlay/Chromecast Output_Devices its audio is
# dispatched to through the Playback_Sidecar.
#
# The selection is the authoritative "active devices" set the
# PartyPlaybackDispatcher plays to: dispatch fans the Shared_Playlist's current
# Song out to every selected device, and when a device becomes unavailable its
# row is removed so playback continues on the remaining devices (and stops once
# none remain — Req 6.4).
class PartyOutputDevice < ApplicationRecord
  belongs_to :party_session
  belongs_to :output_device
end
