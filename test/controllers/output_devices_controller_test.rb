# frozen_string_literal: true

require "test_helper"

class OutputDevicesControllerTest < ActionDispatch::IntegrationTest
  def build_device(name:, protocol: "airplay", requires_password: false)
    OutputDevice.create!(
      identifier: "#{protocol}-#{name}",
      name: name,
      protocol: protocol,
      requires_password: requires_password,
      reachable_at: Time.current
    )
  end

  def stub_discovery(devices: [], available: true, error: nil)
    result = DeviceDiscovery::Result.new(devices: devices, available: available, error: error)
    DeviceDiscovery.stub(:discover, result) { yield }
  end

  test "index renders a graceful empty state when discovery is unavailable" do
    login(users(:visitor1))

    stub_discovery(devices: [], available: false, error: "playback sidecar is unreachable") do
      get output_devices_path
    end

    assert_response :success
    assert_match "No playback sidecar is reachable", @response.body
  end

  test "index lists discovered devices with a cast action in client_cast mode" do
    user = users(:visitor1)
    user.update!(playback_mode: "client_cast")
    login(user)
    device = build_device(name: "Living Room")

    stub_discovery(devices: [ device ], available: true) do
      get output_devices_path
    end

    assert_response :success
    assert_match "Living Room", @response.body
    assert_match I18n.t("button.cast_here"), @response.body
  end

  test "index reports devices and availability as JSON" do
    login(users(:visitor1))
    device = build_device(name: "Kitchen", protocol: "chromecast")

    stub_discovery(devices: [ device ], available: true) do
      get output_devices_path, as: :json
    end

    assert_response :success
    body = @response.parsed_body
    assert body["discovery_available"]
    assert_equal "Kitchen", body["devices"].first["name"]
    assert_equal "chromecast", body["devices"].first["protocol"]
  end

  test "selecting a device from the web UI sets the cast target and redirects" do
    user = users(:visitor1)
    user.update!(playback_mode: "client_cast")
    login(user)
    device = build_device(name: "Office")

    post cast_session_path,
      params: { target_output_device_id: device.id },
      headers: { "HTTP_REFERER" => output_devices_url }

    assert_response :redirect
    assert_equal device.id, CastSession.find_by(user: user).target_output_device_id
  end

  test "playing with no selected device is rejected and redirects with an alert" do
    user = users(:visitor1)
    user.update!(playback_mode: "client_cast")
    CastSession.create!(user: user, state: "stopped", target_output_device_id: nil)
    login(user)

    post play_cast_session_path, headers: { "HTTP_REFERER" => output_devices_url }

    assert_redirected_to output_devices_path
    assert_equal "stopped", CastSession.find_by(user: user).state
  end
end
