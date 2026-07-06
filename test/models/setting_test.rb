# frozen_string_literal: true

require "test_helper"

class SettingTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  test "should have AVAILABLE_SETTINGS constant" do
    assert_equal [ :media_path, :discogs_token, :transcode_bitrate, :allow_transcode_lossless, :enable_media_listener, :enable_parallel_media_sync, :enable_daap, :enable_rsp, :setlistfm_api_key, :server_base_url, :max_concurrent_streams ], Setting::AVAILABLE_SETTINGS
  end

  # Admin/global concurrency cap for Radio_Station and Co_Listen_Session
  # broadcasts (Req 10.5). Registered via has_setting with no default, so it
  # reports nil (unbounded) until an Admin configures it.
  test "max_concurrent_streams defaults to nil when unset" do
    assert_nil Setting.max_concurrent_streams
  end

  test "max_concurrent_streams is stored as an integer once set" do
    Setting.update(max_concurrent_streams: "5")

    assert_equal 5, Setting.max_concurrent_streams
  end

  test "should default enable_daap and enable_rsp to false" do
    assert_not Setting.enable_daap
    assert_not Setting.enable_rsp
  end

  test "should independently toggle enable_daap and enable_rsp" do
    Setting.update(enable_daap: true)

    assert Setting.enable_daap
    assert_not Setting.enable_rsp

    Setting.update(enable_rsp: true)

    assert Setting.enable_daap
    assert Setting.enable_rsp

    Setting.update(enable_daap: false)

    assert_not Setting.enable_daap
    assert Setting.enable_rsp
  end

  test "should get env default value when setting value did not set" do
    Setting.instance.stub(:values, { "media_path" => nil }) do
      with_env("MEDIA_PATH" => "/test_media_path") do
        assert_equal "/test_media_path", Setting.media_path
      end
    end
  end

  test "should get singleton global setting" do
    assert_equal Setting.instance, Setting.instance
  end

  test "should update settings" do
    assert_nil Setting.discogs_token

    Setting.update(discogs_token: "token")

    assert_equal "token", Setting.discogs_token
  end

  test "should update multiple settings" do
    Setting.update(discogs_token: "token", transcode_bitrate: 192, allow_transcode_lossless: true)

    assert_equal "token", Setting.discogs_token
    assert_equal 192, Setting.transcode_bitrate
    assert Setting.allow_transcode_lossless
  end

  test "should update setting when alreay have others settings" do
    Setting.update(transcode_bitrate: 192)
    Setting.update(discogs_token: "token")

    assert_equal 192, Setting.transcode_bitrate
    assert_equal "token", Setting.discogs_token
  end

  test "should get default value when setting value did not set" do
    assert_nil Setting.instance.values&.[]("transcode_bitrate")
    assert_equal 128, Setting.transcode_bitrate
  end

  test "should get right type value when set type option" do
    assert_not Setting.allow_transcode_lossless
    Setting.update(allow_transcode_lossless: 1)

    assert Setting.allow_transcode_lossless
  end

  test "should validate transcode_bitrate options" do
    setting = Setting.instance
    setting.update(transcode_bitrate: 10)

    assert_not setting.valid?
  end

  test "should validate media_path" do
    setting = Setting.instance
    setting.update(media_path: "/not_exist")

    assert_not setting.valid?
  end

  test "should sync media when media_path changed" do
    assert_enqueued_with(job: MediaSyncAllJob) do
      Setting.update(media_path: Rails.root.join("test/fixtures"))
    end
  end

  test "should toggle media listener when enable_media_listener changed" do
    Setting.update(enable_media_listener: true)
    assert MediaListener.running?

    Setting.update(enable_media_listener: false)
    assert_not MediaListener.running?
  end

  test "server_base_url falls back to the env config when unset" do
    Setting.instance.stub(:values, { "server_base_url" => nil }) do
      with_env("SERVER_BASE_URL" => "https://music.example.com") do
        assert_equal "https://music.example.com", Setting.server_base_url
      end
    end
  end

  test "a configured server_base_url overrides the env config" do
    Setting.update(server_base_url: "https://my.host.example")

    assert_equal "https://my.host.example", Setting.server_base_url
  end

  test "rejects a server_base_url that is not an absolute http(s) URL" do
    setting = Setting.instance

    setting.update(server_base_url: "not a url")
    assert_not setting.valid?

    setting.update(server_base_url: "ftp://host")
    assert_not setting.valid?
  end

  test "accepts a valid server_base_url and a blank one" do
    setting = Setting.instance

    setting.server_base_url = "https://music.example.com"
    assert setting.valid?

    setting.server_base_url = ""
    assert setting.valid?
  end

  test "should validate when enable parallel media sync" do
    setting = Setting.instance

    with_env("DB_ADAPTER" => "sqlite") do
      setting.update(enable_parallel_media_sync: true)
      assert_not setting.valid?
    end

    with_env("DB_ADAPTER" => "postgresql") do
      setting.update(enable_parallel_media_sync: true)
      assert setting.valid?
    end
  end
end
