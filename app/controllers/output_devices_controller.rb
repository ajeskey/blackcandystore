# frozen_string_literal: true

# Browser-facing device picker and cast-control hub for the current User's
# `client_cast` Playback_Mode (Req 13, 17).
#
# `index` runs a Device_Discovery cycle (DeviceDiscovery.discover) to list the
# AirPlay/Chromecast Output_Devices currently advertised on the local network.
# Discovery is backed by an out-of-process playback sidecar; when that sidecar
# is absent or unreachable, discovery degrades gracefully to an empty set with
# an "unavailable" indication rather than raising (Req 13.5), which the view
# surfaces as an explanatory empty state.
#
# The page also renders the User's current Cast_Session so the picker can show
# which device is selected and drive the play/pause/stop state machine through
# CastSessionsController. Casting the actual audio to the device happens on the
# client (Req 17.15); this hub only selects the target and mirrors the state.
class OutputDevicesController < ApplicationController
  def index
    result = DeviceDiscovery.discover

    @devices = result.devices
    @discovery_available = result.available
    @discovery_error = result.error
    @playback_mode = Current.user.playback_mode
    @cast_session = CastSession.find_or_initialize_by(user: Current.user)

    respond_to do |format|
      format.html
      format.json do
        render json: {
          discovery_available: @discovery_available,
          devices: @devices.map { |device| device_json(device) }
        }
      end
    end
  end

  private

  def device_json(device)
    {
      id: device.id,
      name: device.name,
      protocol: device.protocol,
      requires_password: device.requires_password
    }
  end
end
