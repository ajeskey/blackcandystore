# frozen_string_literal: true

require "test_helper"

class OutputDeviceTest < ActiveSupport::TestCase
  def build_device(**attrs)
    OutputDevice.new(
      identifier: "device-abc",
      name: "Living Room",
      protocol: "airplay",
      **attrs
    )
  end

  test "is valid with a protocol, name and identifier" do
    assert build_device.valid?
  end

  test "requires an identifier (Req 13.1)" do
    device = build_device(identifier: nil)
    assert_not device.valid?
    assert_includes device.errors.attribute_names, :identifier
  end

  test "enforces a unique identifier so re-discovery updates one row (Req 13.3)" do
    build_device.save!
    duplicate = build_device(name: "Kitchen")
    assert_not duplicate.valid?
    assert_includes duplicate.errors.attribute_names, :identifier
  end

  test "classifies protocol as exactly airplay or chromecast (Req 13.6)" do
    OutputDevice::PROTOCOLS.each do |protocol|
      assert build_device(identifier: "d-#{protocol}", protocol: protocol).valid?
    end

    assert_not build_device(protocol: "bluetooth").valid?
  end

  test "defaults requires_password to false (Req 13.2, 13.4)" do
    device = build_device
    device.save!
    assert_equal false, device.reload.requires_password
  end

  test "records a password requirement when set (Req 13.4)" do
    device = build_device(requires_password: true)
    device.save!
    assert_equal true, device.reload.requires_password
  end
end
