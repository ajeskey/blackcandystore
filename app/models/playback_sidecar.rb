# frozen_string_literal: true

require "httparty"

# Playback_Sidecar is the thin Rails-side seam that dispatches decoded audio to
# the out-of-process **playback sidecar** which owns the AirPlay/Chromecast wire
# protocols (see the design's Notable Technical Risks). The Rails side owns the
# Playback_Session state machine (PlaybackController, task 24.1); this module
# only translates a "play this stream on these devices" intent into a local
# HTTP call to the sidecar and maps its responses back into domain outcomes.
#
# It deliberately mirrors DeviceDiscovery::SidecarClient: an injectable client
# seam reached over local HTTP, short timeouts because the sidecar is local, and
# transport failures translated into a domain error rather than leaking. The
# real synchronized multi-room framing lives entirely in the sidecar and is only
# exercised by integration/smoke tests (task 24.3) — never by Ruby.
module PlaybackSidecar
  # ENV var holding the playback sidecar's base URL. Shares the sidecar with
  # Device_Discovery, so it reuses the same variable and loopback default.
  SIDECAR_URL_ENV = "PLAYBACK_SIDECAR_URL"
  DEFAULT_SIDECAR_URL = "http://127.0.0.1:9330"

  # The sidecar endpoint that starts audio playback on a set of Output_Devices.
  PLAY_PATH = "/play"

  # How long (seconds) to wait on the local sidecar before treating the dispatch
  # as failed. The sidecar is local, so this is deliberately short.
  DISPATCH_TIMEOUT = 5

  # Raised when the sidecar cannot be reached or answers with a non-success,
  # non-auth response. Translated by the caller into a dispatch failure so the
  # session state machine never sees a raw transport error.
  class Unavailable < StandardError; end

  # Raised when the sidecar rejects the play command because a password-protected
  # Output_Device's credentials were missing or incorrect (Req 14.8). Translated
  # by the caller into an authentication failure.
  class AuthenticationError < StandardError; end

  # Talks to the playback sidecar over local HTTP. `play` POSTs a play command
  # describing the devices, the resolved stream to decode, and any per-device
  # credentials; it returns the parsed sidecar acknowledgement on success and
  # raises AuthenticationError / Unavailable otherwise.
  class Client
    def initialize(base_url: PlaybackSidecar.sidecar_url)
      @base_url = base_url.to_s.chomp("/")
    end

    # Dispatch a play command to the sidecar.
    #
    # @param device_ids [Array<Integer>] the active Output_Devices to play on;
    #   more than one drives a synchronized multi-room group (Req 14.2)
    # @param stream_source [String] "local" or "remote" — which decoding path the
    #   sidecar should use for the current Song (Req 14.9, 14.10)
    # @param stream_url [String] the resolved same-origin path the sidecar fetches
    #   the audio from (a current-server stream path for local content, the remote
    #   proxy path for Remote_Library content)
    # @param credentials [Hash] per-device passwords keyed by device id, for
    #   password-protected AirPlay_Devices (Req 14.7)
    # @return [Hash] the parsed sidecar acknowledgement
    def play(device_ids:, stream_source:, stream_url:, credentials: {})
      response = HTTParty.post(
        "#{@base_url}#{PLAY_PATH}",
        headers: {"Content-Type" => "application/json", "Accept" => "application/json"},
        body: {
          device_ids: device_ids,
          stream_source: stream_source,
          stream_url: stream_url,
          credentials: credentials
        }.to_json,
        open_timeout: DISPATCH_TIMEOUT,
        read_timeout: DISPATCH_TIMEOUT
      )

      code = response.code.to_i
      if code == 401 || code == 403
        raise AuthenticationError, "playback sidecar rejected device credentials (HTTP #{code})"
      end

      unless code.between?(200, 299)
        raise Unavailable, "playback sidecar returned HTTP #{code}"
      end

      parse(response.body)
    rescue Net::OpenTimeout, Net::ReadTimeout, ::Timeout::Error => e
      raise Unavailable, "playback sidecar did not respond within #{DISPATCH_TIMEOUT}s: #{e.message}"
    rescue SocketError, Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH,
      Errno::ENETUNREACH, OpenSSL::SSL::SSLError, HTTParty::Error => e
      raise Unavailable, "playback sidecar is unreachable: #{e.message}"
    end

    private

    def parse(body)
      return {} if body.blank?

      JSON.parse(body)
    rescue JSON::ParserError
      {}
    end
  end

  class << self
    # The sidecar base URL, from ENV with a loopback default (shared with
    # Device_Discovery so a co-located sidecar needs zero configuration).
    def sidecar_url
      value = ENV[SIDECAR_URL_ENV].to_s.strip
      value.presence || DEFAULT_SIDECAR_URL
    end

    def client
      Client.new
    end
  end
end
