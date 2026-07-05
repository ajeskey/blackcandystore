# frozen_string_literal: true

require "test_helper"

class DeviceDiscoveryTest < ActiveSupport::TestCase
  # A minimal in-memory stand-in for the playback sidecar client so the
  # reconciliation logic can be exercised without any HTTP/IPC. The real
  # sidecar integration is covered by task 23.3.
  class FakeSidecarClient
    def initialize(devices)
      @devices = devices
    end

    def list_devices
      @devices
    end
  end

  # A client that always fails to reach the sidecar.
  class AbsentSidecarClient
    def list_devices
      raise DeviceDiscovery::Unavailable, "playback sidecar is unreachable"
    end
  end

  setup do
    OutputDevice.delete_all
  end

  test "classifies and upserts devices from a stubbed sidecar response (Req 13.1, 13.6)" do
    client = FakeSidecarClient.new([
      { "identifier" => "airplay-1", "name" => "Living Room", "protocol" => "airplay", "requires_password" => false },
      { "identifier" => "cast-1", "name" => "Kitchen", "protocol" => "chromecast", "requires_password" => false }
    ])

    result = DeviceDiscovery.discover(client: client)

    assert result.available?
    assert_nil result.error
    assert_equal %w[airplay-1 cast-1], result.devices.map(&:identifier).sort
    assert_equal %w[airplay chromecast], OutputDevice.order(:protocol).pluck(:protocol)
    result.devices.each { |device| assert_includes OutputDevice::PROTOCOLS, device.protocol }
  end

  test "records each device's password requirement (Req 13.2, 13.4)" do
    client = FakeSidecarClient.new([
      { "identifier" => "airplay-locked", "name" => "Office", "protocol" => "airplay", "requires_password" => true },
      { "identifier" => "airplay-open", "name" => "Patio", "protocol" => "airplay", "requires_password" => false }
    ])

    DeviceDiscovery.discover(client: client)

    assert_equal true, OutputDevice.find_by(identifier: "airplay-locked").requires_password
    assert_equal false, OutputDevice.find_by(identifier: "airplay-open").requires_password
  end

  test "returns every reachable device with its classification (Req 13.2)" do
    client = FakeSidecarClient.new([
      { "identifier" => "a", "protocol" => "airplay", "requires_password" => true },
      { "identifier" => "b", "protocol" => "chromecast", "requires_password" => false }
    ])

    devices = DeviceDiscovery.available_devices(client: client)

    assert_equal 2, devices.length
    assert(devices.all? { |device| OutputDevice::PROTOCOLS.include?(device.protocol) })
  end

  test "re-discovering an advertised device updates the same row (Req 13.1)" do
    first = FakeSidecarClient.new([
      { "identifier" => "airplay-1", "name" => "Living Room", "protocol" => "airplay", "requires_password" => false }
    ])
    DeviceDiscovery.discover(client: first)

    second = FakeSidecarClient.new([
      { "identifier" => "airplay-1", "name" => "Living Room (renamed)", "protocol" => "airplay", "requires_password" => true }
    ])
    result = DeviceDiscovery.discover(client: second)

    assert_equal 1, OutputDevice.count
    device = OutputDevice.find_by(identifier: "airplay-1")
    assert_equal "Living Room (renamed)", device.name
    assert_equal true, device.requires_password
    assert_equal [ "airplay-1" ], result.devices.map(&:identifier)
  end

  test "removes devices that stop being advertised (Req 13.3)" do
    present = FakeSidecarClient.new([
      { "identifier" => "airplay-1", "protocol" => "airplay" },
      { "identifier" => "cast-1", "protocol" => "chromecast" }
    ])
    DeviceDiscovery.discover(client: present)
    assert_equal 2, OutputDevice.count

    # cast-1 stops advertising; only airplay-1 remains.
    remaining = FakeSidecarClient.new([
      { "identifier" => "airplay-1", "protocol" => "airplay" }
    ])
    result = DeviceDiscovery.discover(client: remaining)

    assert_equal [ "airplay-1" ], OutputDevice.pluck(:identifier)
    assert_equal [ "airplay-1" ], result.devices.map(&:identifier)
    assert_nil OutputDevice.find_by(identifier: "cast-1")
  end

  test "removes all devices when none are advertised (Req 13.3)" do
    DeviceDiscovery.discover(client: FakeSidecarClient.new([
      { "identifier" => "airplay-1", "protocol" => "airplay" }
    ]))
    assert_equal 1, OutputDevice.count

    result = DeviceDiscovery.discover(client: FakeSidecarClient.new([]))

    assert result.available?
    assert_empty result.devices
    assert_equal 0, OutputDevice.count
  end

  test "ignores devices that cannot be classified as exactly one protocol (Property 23, Req 13.6)" do
    client = FakeSidecarClient.new([
      { "identifier" => "airplay-1", "protocol" => "airplay" },
      { "identifier" => "bt-1", "protocol" => "bluetooth" },
      { "identifier" => "blank-1", "protocol" => "" },
      { "identifier" => "", "protocol" => "airplay" }
    ])

    result = DeviceDiscovery.discover(client: client)

    assert_equal [ "airplay-1" ], result.devices.map(&:identifier)
    assert_equal [ "airplay-1" ], OutputDevice.pluck(:identifier)
  end

  test "returns an empty set and an unavailable indication when the sidecar is absent (Req 13.5)" do
    result = DeviceDiscovery.discover(client: AbsentSidecarClient.new)

    assert_not result.available?
    assert_empty result.devices
    assert_not_nil result.error
    assert_equal [], DeviceDiscovery.available_devices(client: AbsentSidecarClient.new)
  end

  test "leaves cached devices untouched on a transient sidecar failure (Req 13.5)" do
    DeviceDiscovery.discover(client: FakeSidecarClient.new([
      { "identifier" => "airplay-1", "protocol" => "airplay" }
    ]))
    assert_equal 1, OutputDevice.count

    DeviceDiscovery.discover(client: AbsentSidecarClient.new)

    # A momentary sidecar blip must not flap the cached device list.
    assert_equal 1, OutputDevice.count
  end

  test "degrades gracefully when the sidecar connection is refused (Req 13.5)" do
    url = "http://127.0.0.1:9330"
    stub_request(:get, "#{url}/devices").to_raise(Errno::ECONNREFUSED)

    with_env(DeviceDiscovery::SIDECAR_URL_ENV => url) do
      result = DeviceDiscovery.discover

      assert_not result.available?
      assert_empty result.devices
      assert_not_nil result.error
    end
  end

  test "enumerates devices from the sidecar over HTTP (Req 13.1)" do
    url = "http://127.0.0.1:9330"
    body = {
      devices: [
        { identifier: "airplay-1", name: "Living Room", protocol: "airplay", requires_password: true },
        { identifier: "cast-1", name: "Kitchen", protocol: "chromecast", requires_password: false }
      ]
    }.to_json
    stub_request(:get, "#{url}/devices").to_return(status: 200, body: body, headers: { "Content-Type" => "application/json" })

    with_env(DeviceDiscovery::SIDECAR_URL_ENV => url) do
      result = DeviceDiscovery.discover

      assert result.available?
      assert_equal %w[airplay-1 cast-1], result.devices.map(&:identifier).sort
      assert_equal true, OutputDevice.find_by(identifier: "airplay-1").requires_password
    end
  end

  test "treats a non-success sidecar response as unavailable (Req 13.5)" do
    url = "http://127.0.0.1:9330"
    stub_request(:get, "#{url}/devices").to_return(status: 503)

    with_env(DeviceDiscovery::SIDECAR_URL_ENV => url) do
      result = DeviceDiscovery.discover

      assert_not result.available?
      assert_empty result.devices
    end
  end

  test "sidecar_url falls back to the loopback default when unset" do
    with_env(DeviceDiscovery::SIDECAR_URL_ENV => nil) do
      assert_equal DeviceDiscovery::DEFAULT_SIDECAR_URL, DeviceDiscovery.sidecar_url
    end
  end
end
