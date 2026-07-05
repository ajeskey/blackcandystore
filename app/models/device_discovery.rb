# frozen_string_literal: true

require "httparty"

# Device_Discovery discovers the AirPlay_Devices and Chromecast_Devices
# advertised on the local network and maintains the current set of reachable
# Output_Devices (Req 13).
#
# There is no mature, maintained pure-Ruby AirPlay 2 / Chromecast sender stack
# (see the design's Notable Technical Risks), so the actual mDNS enumeration and
# wire-protocol work lives in an out-of-process **playback sidecar** reached over
# a local HTTP/IPC boundary. This Rails-side module is a thin translator: it asks
# the sidecar for the currently advertised devices, classifies each as exactly
# one protocol (Req 13.6), records each device's password requirement (Req 13.2,
# 13.4), and reconciles the `OutputDevice` cache — adding devices as they appear
# and removing them as they stop being advertised (Req 13.1, 13.3).
#
# When the sidecar is absent or unreachable, discovery degrades gracefully:
# it returns an empty set of available devices together with an indication that
# discovery is unavailable, and never raises (Req 13.5). The existing cached
# rows are left untouched on a transient sidecar failure so a momentary blip
# does not flap the device list.
#
# The sidecar HTTP call is isolated behind an injectable client seam
# (`DeviceDiscovery::SidecarClient`) so unit tests can stub it directly or via
# WebMock. The real sidecar integration/smoke coverage is task 23.3.
module DeviceDiscovery
  # The protocols a discovered device may be classified as. A discovered device
  # is recorded only when it can be classified as exactly one of these
  # (Property 23, Req 13.6); anything else is ignored rather than persisted.
  PROTOCOLS = OutputDevice::PROTOCOLS

  # ENV var holding the playback sidecar's base URL. Defaults to a loopback
  # address so a co-located sidecar works with zero configuration.
  SIDECAR_URL_ENV = "PLAYBACK_SIDECAR_URL"
  DEFAULT_SIDECAR_URL = "http://127.0.0.1:9330"

  # The sidecar endpoint that returns the currently advertised devices.
  DISCOVERY_PATH = "/devices"

  # How long (seconds) to wait on the local sidecar before treating discovery
  # as unavailable. The sidecar is local, so this is deliberately short.
  DISCOVERY_TIMEOUT = 5

  # The outcome of a discovery run. `devices` is the current set of reachable
  # Output_Devices (empty when discovery is unavailable), `available?` indicates
  # whether the sidecar could be reached and enumerated, and `error` carries a
  # human-readable reason when it could not (Req 13.5).
  Result = Struct.new(:devices, :available, :error, keyword_init: true) do
    def available?
      available
    end
  end

  # Raised internally by the sidecar client when the sidecar cannot be reached
  # or does not answer successfully. Callers of the module never see this — it
  # is translated into an "unavailable" Result (Req 13.5).
  class Unavailable < StandardError; end

  # Talks to the playback sidecar over local HTTP. Returns the list of advertised
  # devices as an array of hashes; raises Unavailable on any transport failure or
  # non-success response so the module can degrade gracefully.
  class SidecarClient
    def initialize(base_url: DeviceDiscovery.sidecar_url)
      @base_url = base_url.to_s.chomp("/")
    end

    # @return [Array<Hash>] the raw advertised-device descriptors from the sidecar
    def list_devices
      response = HTTParty.get(
        "#{@base_url}#{DISCOVERY_PATH}",
        headers: {"Accept" => "application/json"},
        open_timeout: DISCOVERY_TIMEOUT,
        read_timeout: DISCOVERY_TIMEOUT
      )

      unless response.code.to_i.between?(200, 299)
        raise Unavailable, "playback sidecar returned HTTP #{response.code}"
      end

      parse(response.body)
    rescue Net::OpenTimeout, Net::ReadTimeout, ::Timeout::Error => e
      raise Unavailable, "playback sidecar did not respond within #{DISCOVERY_TIMEOUT}s: #{e.message}"
    rescue SocketError, Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH,
      Errno::ENETUNREACH, OpenSSL::SSL::SSLError, HTTParty::Error => e
      raise Unavailable, "playback sidecar is unreachable: #{e.message}"
    end

    private

    def parse(body)
      return [] if body.blank?

      payload = JSON.parse(body)
      list = payload.is_a?(Hash) ? payload["devices"] : payload
      Array(list)
    rescue JSON::ParserError => e
      raise Unavailable, "playback sidecar returned an unparseable response: #{e.message}"
    end
  end

  class << self
    # Convenience accessor matching the design signature: the current set of
    # reachable Output_Devices, or an empty array when discovery is unavailable
    # (Req 13.2, 13.5).
    #
    # @return [Array<OutputDevice>]
    def available_devices(client: default_client)
      discover(client: client).devices
    end

    # Run a discovery cycle: ask the sidecar for advertised devices, classify and
    # upsert each reachable device, remove devices that have stopped advertising,
    # and return the reconciled set (Req 13.1, 13.3, 13.6). On sidecar
    # absence/unreachability, return an empty set with an "unavailable"
    # indication and leave the cache untouched (Req 13.5).
    #
    # @return [DeviceDiscovery::Result]
    def discover(client: default_client)
      advertised = client.list_devices
      devices = reconcile(advertised)
      Result.new(devices: devices, available: true, error: nil)
    rescue Unavailable => e
      Result.new(devices: [], available: false, error: e.message)
    end

    # The sidecar base URL, from ENV with a loopback default.
    def sidecar_url
      value = ENV[SIDECAR_URL_ENV].to_s.strip
      value.presence || DEFAULT_SIDECAR_URL
    end

    private

    def default_client
      SidecarClient.new
    end

    # Reconcile the advertised-device set into the OutputDevice cache, keyed by
    # identifier. Upserts each classifiable advertised device (Req 13.1) and
    # deletes cached devices that no longer advertise (Req 13.3). Devices that
    # cannot be classified as exactly one protocol are ignored so every cached
    # row carries a valid protocol (Property 23, Req 13.6).
    def reconcile(advertised)
      classified = advertised.filter_map { |raw| normalize(raw) }
      seen_identifiers = classified.map { |attrs| attrs[:identifier] }

      OutputDevice.transaction do
        # Remove devices that disappeared, regardless of how many times they were
        # previously discovered (Req 13.3).
        if seen_identifiers.empty?
          OutputDevice.delete_all
        else
          OutputDevice.where.not(identifier: seen_identifiers).delete_all
        end

        classified.map { |attrs| upsert(attrs) }
      end
    end

    def upsert(attrs)
      device = OutputDevice.find_or_initialize_by(identifier: attrs[:identifier])
      device.name = attrs[:name]
      device.protocol = attrs[:protocol]
      device.requires_password = attrs[:requires_password]
      device.reachable_at = Time.current
      device.save!
      device
    end

    # Normalize one raw advertised-device descriptor into OutputDevice attributes,
    # or nil when it lacks an identifier or cannot be classified as exactly one of
    # airplay/chromecast (Property 23, Req 13.6).
    def normalize(raw)
      return nil unless raw.is_a?(Hash)

      attrs = raw.transform_keys(&:to_s)
      identifier = (attrs["identifier"] || attrs["id"]).to_s.strip
      return nil if identifier.blank?

      protocol = attrs["protocol"].to_s.strip.downcase
      return nil unless PROTOCOLS.include?(protocol)

      {
        identifier: identifier,
        name: attrs["name"].presence,
        protocol: protocol,
        requires_password: coerce_boolean(attrs["requires_password"] || attrs["password_required"])
      }
    end

    def coerce_boolean(value)
      ActiveModel::Type::Boolean.new.cast(value) || false
    end
  end
end
