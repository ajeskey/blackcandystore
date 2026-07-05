# frozen_string_literal: true

require "test_helper"

# Property-based test for output-device classification during discovery.
#
# Design property (multi-server-library-sharing, Property 23):
#   For any set of discovered Output_Devices, each is classified as exactly one
#   of `airplay`/`chromecast` and each device's password requirement is reported.
#
# `DeviceDiscovery.discover(client:)` asks an injected sidecar client for the
# raw advertised-device descriptors, classifies each as exactly one protocol
# (Req 13.6), records whether it requires a password (Req 13.2), and upserts it
# keyed by identifier. Descriptors that cannot be classified as exactly one of
# airplay/chromecast — unknown/blank/nil protocols — or that lack an identifier
# are skipped rather than persisted.
#
# This test drives discovery with a GENERATED set of raw descriptors mixing
# valid devices (advertising airplay/chromecast, possibly case-variant) with
# invalid ones (bluetooth, "", nil, garbage, blank identifier) and random
# password requirements, then asserts the classification invariants hold across
# the whole set.
class OutputDeviceClassificationPropertyTest < ActiveSupport::TestCase
  # A minimal in-memory stand-in for the playback sidecar client: `list_devices`
  # returns the generated raw descriptors unchanged (mirrors the fake in
  # test/models/device_discovery_test.rb).
  class FakeSidecarClient
    def initialize(devices)
      @devices = devices
    end

    def list_devices
      @devices
    end
  end

  # Feature: multi-server-library-sharing, Property 23: Output devices are classified with exactly one protocol
  test "every discovered device is classified as exactly one of airplay/chromecast with its password requirement recorded, and unclassifiable devices are excluded" do
    check_property(iterations: 100) do
      # Build a set of 1..8 raw advertised-device descriptors. Each spec carries
      # the `:raw` descriptor handed to the sidecar and the `:expected`
      # classification (nil when the descriptor must be excluded). Identifiers
      # are prefixed with the index so valid devices never collide.
      count = range(1, 8)

      Array.new(count) do |i|
        category = choose(
          :airplay, :airplay, :chromecast, :chromecast, :case_variant,
          :bluetooth, :empty_protocol, :nil_protocol, :garbage, :blank_id
        )
        identifier = "dev-#{i}-" + sized(range(4, 10)) { string(:alnum) }
        name = choose(nil, sized(range(1, 12)) { string(:alnum) })
        requires_password = boolean

        raw = {
          "identifier" => identifier,
          "name" => name,
          "requires_password" => requires_password
        }

        case category
        when :airplay
          raw["protocol"] = "airplay"
          { raw: raw, expected: { identifier: identifier, protocol: "airplay", requires_password: requires_password } }
        when :chromecast
          raw["protocol"] = "chromecast"
          { raw: raw, expected: { identifier: identifier, protocol: "chromecast", requires_password: requires_password } }
        when :case_variant
          # Discovery normalizes case, so a case-variant protocol is still a
          # valid classification of the lower-cased protocol.
          raw["protocol"] = choose("AirPlay", "AIRPLAY", "ChromeCast", "CHROMECAST")
          { raw: raw, expected: { identifier: identifier, protocol: raw["protocol"].downcase, requires_password: requires_password } }
        when :bluetooth
          raw["protocol"] = "bluetooth"
          { raw: raw, expected: nil }
        when :empty_protocol
          raw["protocol"] = ""
          { raw: raw, expected: nil }
        when :nil_protocol
          raw["protocol"] = nil
          { raw: raw, expected: nil }
        when :garbage
          # Prefixed so a random string can never accidentally spell a valid protocol.
          raw["protocol"] = "x-" + sized(range(1, 8)) { string(:alnum) }
          { raw: raw, expected: nil }
        when :blank_id
          # Valid protocol but no usable identifier => cannot be classified/persisted.
          raw["identifier"] = choose("", "   ")
          raw["protocol"] = "airplay"
          { raw: raw, expected: nil }
        end
      end
    end.check do |specs|
      # Reset the discovery cache so each generated set is evaluated in isolation.
      OutputDevice.delete_all

      raws = specs.map { |spec| spec[:raw] }
      result = DeviceDiscovery.discover(client: FakeSidecarClient.new(raws))

      assert result.available?, "discovery should be available for a well-formed sidecar response"

      expected = specs.filter_map { |spec| spec[:expected] }
      expected_by_id = expected.index_by { |attrs| attrs[:identifier] }

      returned = result.devices

      # Req 13.6 (Property 23): every returned/persisted device is classified as
      # EXACTLY one of the two protocols.
      returned.each do |device|
        matches = OutputDevice::PROTOCOLS.select { |protocol| protocol == device.protocol }
        assert_equal 1, matches.length,
          "device #{device.identifier.inspect} must be classified as exactly one protocol, got #{device.protocol.inspect}"
      end

      # The returned set — and the persisted cache — is exactly the set of valid
      # generated devices; unclassifiable descriptors are excluded.
      assert_equal expected_by_id.keys.sort, returned.map(&:identifier).sort
      assert_equal expected_by_id.keys.sort, OutputDevice.pluck(:identifier).sort

      # Req 13.2: each valid device is classified with the protocol it advertised
      # and its password requirement is recorded correctly.
      expected.each do |attrs|
        persisted = OutputDevice.find_by(identifier: attrs[:identifier])
        refute_nil persisted, "expected valid device #{attrs[:identifier].inspect} to be persisted"
        assert_equal attrs[:protocol], persisted.protocol,
          "device #{attrs[:identifier].inspect} should be classified as the advertised protocol"
        assert_equal attrs[:requires_password], persisted.requires_password,
          "device #{attrs[:identifier].inspect} should record its password requirement"
      end
    end
  end
end
