# frozen_string_literal: true

require "test_helper"

# Integration / smoke test for Device_Discovery's playback-sidecar boundary
# (multi-server-library-sharing, task 23.3).
#
# There is no maintained pure-Ruby AirPlay 2 / Chromecast stack, so the actual
# mDNS enumeration and wire-protocol work lives in an out-of-process playback
# sidecar reached over a local HTTP/IPC boundary. DeviceDiscovery is a thin
# translator that asks the sidecar for the currently advertised devices and
# reconciles the OutputDevice cache.
#
# These tests exercise the full discovery flow across that HTTP boundary. Every
# sidecar response is stubbed with WebMock (the suite disallows real net
# connections): a stubbed JSON body stands in for the set of mDNS-advertised
# devices the sidecar would enumerate. We drive DeviceDiscovery.discover through
# the real SidecarClient (no injected fake) so the HTTP request, parsing, and
# reconciliation are all covered end-to-end:
#
#   * devices the sidecar advertises are discovered and persisted        (Req 13.1)
#   * across two discovery cycles, an appearing device is added and a
#     disappearing device is removed                                     (Req 13.3)
#   * a password-protected AirPlay_Device is flagged as requiring a password (Req 13.4)
#   * SMOKE: when the sidecar is absent (connection refused / timeout),
#     discovery returns an empty set gracefully, reports unavailable,
#     and never raises                                                   (Req 13.5)
#
# This complements — and does not duplicate — the unit tests in
# test/models/device_discovery_test.rb: those assert reconciliation logic
# against an injected in-memory client, while these assert the HTTP/sidecar
# boundary and multi-cycle reconciliation through the real client.
#
# These are NOT property-based tests — they are integration/smoke tests of the
# sidecar request/response flow and its failure translation.
class DeviceDiscoverySidecarTest < ActionDispatch::IntegrationTest
  SIDECAR_URL = "http://127.0.0.1:9330"
  DEVICES_ENDPOINT = "#{SIDECAR_URL}/devices"

  setup do
    OutputDevice.delete_all
  end

  # Stub the sidecar's /devices endpoint with a JSON body representing the set of
  # devices the sidecar has enumerated via mDNS on the local network.
  def stub_sidecar_advertising(devices)
    stub_request(:get, DEVICES_ENDPOINT)
      .to_return(
        status: 200,
        body: { devices: devices }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
  end

  test "discovers and persists devices the sidecar advertises over HTTP (Req 13.1)" do
    stub_sidecar_advertising([
      { identifier: "airplay-1", name: "Living Room", protocol: "airplay", requires_password: false },
      { identifier: "cast-1", name: "Kitchen", protocol: "chromecast", requires_password: false }
    ])

    with_env(DeviceDiscovery::SIDECAR_URL_ENV => SIDECAR_URL) do
      result = DeviceDiscovery.discover

      assert result.available?, "expected discovery to be available when the sidecar responds"
      assert_nil result.error
      assert_equal %w[airplay-1 cast-1], result.devices.map(&:identifier).sort
    end

    # The advertised devices were persisted as Output_Devices with their
    # protocol classification (Req 13.1, 13.6).
    assert_equal 2, OutputDevice.count
    assert_equal "airplay", OutputDevice.find_by(identifier: "airplay-1").protocol
    assert_equal "chromecast", OutputDevice.find_by(identifier: "cast-1").protocol
    assert_requested :get, DEVICES_ENDPOINT
  end

  test "adds an appearing device and removes a disappearing one across two cycles (Req 13.3)" do
    # First discovery cycle: the sidecar advertises airplay-1 and cast-1.
    stub_sidecar_advertising([
      { identifier: "airplay-1", name: "Living Room", protocol: "airplay" },
      { identifier: "cast-1", name: "Kitchen", protocol: "chromecast" }
    ])

    with_env(DeviceDiscovery::SIDECAR_URL_ENV => SIDECAR_URL) do
      first = DeviceDiscovery.discover
      assert_equal %w[airplay-1 cast-1], first.devices.map(&:identifier).sort
    end
    assert_equal %w[airplay-1 cast-1], OutputDevice.order(:identifier).pluck(:identifier)

    # Second cycle: cast-1 stops advertising and a new device airplay-2 appears.
    WebMock.reset!
    stub_sidecar_advertising([
      { identifier: "airplay-1", name: "Living Room", protocol: "airplay" },
      { identifier: "airplay-2", name: "Bedroom", protocol: "airplay" }
    ])

    with_env(DeviceDiscovery::SIDECAR_URL_ENV => SIDECAR_URL) do
      second = DeviceDiscovery.discover
      assert_equal %w[airplay-1 airplay-2], second.devices.map(&:identifier).sort
    end

    # The appearing device is added, the disappearing one is removed (Req 13.3).
    assert_equal %w[airplay-1 airplay-2], OutputDevice.order(:identifier).pluck(:identifier)
    assert_nil OutputDevice.find_by(identifier: "cast-1")
  end

  test "flags a password-protected AirPlay_Device as requiring a password (Req 13.4)" do
    stub_sidecar_advertising([
      { identifier: "airplay-locked", name: "Office", protocol: "airplay", requires_password: true },
      { identifier: "airplay-open", name: "Patio", protocol: "airplay", requires_password: false }
    ])

    with_env(DeviceDiscovery::SIDECAR_URL_ENV => SIDECAR_URL) do
      DeviceDiscovery.discover
    end

    assert_equal true, OutputDevice.find_by(identifier: "airplay-locked").requires_password
    assert_equal false, OutputDevice.find_by(identifier: "airplay-open").requires_password
  end

  test "SMOKE: returns an empty set gracefully when the sidecar is absent - connection refused (Req 13.5)" do
    stub_request(:get, DEVICES_ENDPOINT).to_raise(Errno::ECONNREFUSED)

    with_env(DeviceDiscovery::SIDECAR_URL_ENV => SIDECAR_URL) do
      result = assert_nothing_raised { DeviceDiscovery.discover }

      assert_not result.available?, "expected discovery to report unavailable when the sidecar is absent"
      assert_empty result.devices
      assert_not_nil result.error

      # available_devices takes the same graceful path (empty set, no raise).
      assert_equal [], DeviceDiscovery.available_devices
    end
  end

  test "SMOKE: returns an empty set gracefully when the sidecar times out (Req 13.5)" do
    stub_request(:get, DEVICES_ENDPOINT).to_timeout

    with_env(DeviceDiscovery::SIDECAR_URL_ENV => SIDECAR_URL) do
      result = assert_nothing_raised { DeviceDiscovery.discover }

      assert_not result.available?
      assert_empty result.devices
      assert_not_nil result.error
    end
  end
end
