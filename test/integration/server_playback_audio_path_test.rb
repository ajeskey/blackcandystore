# frozen_string_literal: true

require "test_helper"

# Integration tests for the server-driven playback AUDIO PATH (Req 14.2, 14.7,
# 14.8, 14.9, 14.10). These exercise the dispatch boundary between the Rails
# Playback_Controller and the out-of-process playback sidecar (design: Notable
# Technical Risks — the sidecar owns AirPlay/Chromecast wire protocols, so this
# is integration/smoke coverage, not property-based).
#
# Task 24.1 implemented the Playback_Controller STATE MACHINE and deferred the
# audio dispatch to the sidecar to this task. This test drives the thin dispatch
# seam added here (`PlaybackController#dispatch_audio` + `PlaybackSidecar`) and
# stubs the sidecar's HTTP /play endpoint with WebMock to verify:
#   - starting playback dispatches audio for the current Song to every active
#     Output_Device via the sidecar (Req 14.2)
#   - a password-protected device requires credentials (Req 14.7, 14.8)
#   - local vs remote decoding paths are exercised (Req 14.9, 14.10)
class ServerPlaybackAudioPathTest < ActionDispatch::IntegrationTest
  SIDECAR_URL = "http://127.0.0.1:9330"
  PLAY_ENDPOINT = "#{SIDECAR_URL}/play"

  setup do
    OutputDevice.delete_all
    PlaybackSession.delete_all
    @user = users(:visitor1)
    @local_song = songs(:mp3_sample)
  end

  # Reachability resolver used to construct a controller whose device selection
  # succeeds without depending on Device_Discovery timestamps.
  def always_reachable
    ->(_device_id) { true }
  end

  def controller_for(user)
    PlaybackController.for_user(user, reachable: always_reachable)
  end

  def airplay_device(identifier:, requires_password: false)
    OutputDevice.create!(
      identifier: identifier,
      name: identifier,
      protocol: "airplay",
      requires_password: requires_password,
      reachable_at: Time.current
    )
  end

  def chromecast_device(identifier:)
    OutputDevice.create!(
      identifier: identifier,
      name: identifier,
      protocol: "chromecast",
      requires_password: false,
      reachable_at: Time.current
    )
  end

  def stub_play_ok
    stub_request(:post, PLAY_ENDPOINT)
      .to_return(status: 200, body: { status: "playing" }.to_json, headers: { "Content-Type" => "application/json" })
  end

  # --- Req 14.9: local song decodes from the current server ------------------

  test "dispatches a local Song's audio to the active device via the sidecar (Req 14.2, 14.9)" do
    device = airplay_device(identifier: "living-room")
    stub_play_ok

    with_env(PlaybackSidecar::SIDECAR_URL_ENV => SIDECAR_URL) do
      controller = controller_for(@user)
      assert controller.select_devices([ device.id ]).ok?
      assert controller.play(song_id: @local_song.id).ok?

      result = controller.dispatch_audio

      assert result.ok?, "expected local audio dispatch to succeed"
    end

    assert_requested :post, PLAY_ENDPOINT do |req|
      body = JSON.parse(req.body)
      body["stream_source"] == "local" &&
        body["device_ids"] == [ device.id ] &&
        body["stream_url"].present? &&
        !body["stream_url"].start_with?("/stream/remote")
    end
  end

  # --- Req 14.2: multi-room group — audio goes to every selected device ------

  test "dispatches synchronized audio to every selected AirPlay device as a group (Req 14.2)" do
    room1 = airplay_device(identifier: "room-1")
    room2 = airplay_device(identifier: "room-2")
    stub_play_ok

    with_env(PlaybackSidecar::SIDECAR_URL_ENV => SIDECAR_URL) do
      controller = controller_for(@user)
      assert controller.select_devices([ room1.id, room2.id ]).ok?
      assert controller.play(song_id: @local_song.id).ok?

      assert controller.dispatch_audio.ok?
    end

    assert_requested :post, PLAY_ENDPOINT do |req|
      JSON.parse(req.body)["device_ids"].sort == [ room1.id, room2.id ].sort
    end
  end

  # --- Req 14.10: remote song retrieved through the Library_Connection -------

  test "dispatches a remote Song's audio through the remote proxy path (Req 14.10)" do
    connection = LibraryConnection.create!(
      user: @user,
      status: :active,
      grant_token: "secret-token"
    )
    remote_library = Library.create!(
      name: "Remote Friend Library",
      kind: :remote,
      library_connection: connection
    )
    remote_song = Song.create!(
      name: "remote_track",
      file_path: "/remote/track.mp3",
      file_path_hash: "remote_track_fph",
      md5_hash: "remote_track_md5",
      artist: artists(:artist1),
      album: albums(:album1),
      library: remote_library,
      duration: 8.0
    )
    device = chromecast_device(identifier: "kitchen")
    stub_play_ok

    with_env(PlaybackSidecar::SIDECAR_URL_ENV => SIDECAR_URL) do
      controller = controller_for(@user)
      assert controller.select_devices([ device.id ]).ok?
      assert controller.play(song_id: remote_song.id).ok?

      result = controller.dispatch_audio(user: @user)

      assert result.ok?, "expected remote audio dispatch to succeed"
    end

    assert_requested :post, PLAY_ENDPOINT do |req|
      body = JSON.parse(req.body)
      body["stream_source"] == "remote" &&
        body["stream_url"] == "/stream/remote/#{remote_song.id}"
    end
  end

  test "rejects dispatch for a remote Song whose connection is not resolvable and never contacts the sidecar (Req 14.10)" do
    connection = LibraryConnection.create!(
      user: @user,
      status: :revoked,
      grant_token: "secret-token"
    )
    remote_library = Library.create!(
      name: "Revoked Remote Library",
      kind: :remote,
      library_connection: connection
    )
    remote_song = Song.create!(
      name: "unreachable_track",
      file_path: "/remote/unreachable.mp3",
      file_path_hash: "unreachable_fph",
      md5_hash: "unreachable_md5",
      artist: artists(:artist1),
      album: albums(:album1),
      library: remote_library,
      duration: 8.0
    )
    device = chromecast_device(identifier: "kitchen")
    stub_play_ok

    with_env(PlaybackSidecar::SIDECAR_URL_ENV => SIDECAR_URL) do
      controller = controller_for(@user)
      assert controller.select_devices([ device.id ]).ok?
      assert controller.play(song_id: remote_song.id).ok?

      result = controller.dispatch_audio(user: @user)

      assert result.rejected?
      assert_equal :song_unavailable, result.error
    end

    assert_not_requested :post, PLAY_ENDPOINT
  end

  # --- Req 14.7 / 14.8: password-protected device requires credentials -------

  test "rejects dispatch to a password-protected device when no credential is supplied and sends no audio (Req 14.7, 14.8)" do
    device = airplay_device(identifier: "locked-office", requires_password: true)
    stub_play_ok

    with_env(PlaybackSidecar::SIDECAR_URL_ENV => SIDECAR_URL) do
      controller = controller_for(@user)
      assert controller.select_devices([ device.id ]).ok?
      assert controller.play(song_id: @local_song.id).ok?

      result = controller.dispatch_audio

      assert result.rejected?
      assert_equal :device_authentication_required, result.error
    end

    # No audio must be sent to the protected device (Req 14.8).
    assert_not_requested :post, PLAY_ENDPOINT
  end

  test "dispatches to a password-protected device when the correct credential is supplied (Req 14.7)" do
    device = airplay_device(identifier: "locked-office", requires_password: true)
    stub_play_ok

    with_env(PlaybackSidecar::SIDECAR_URL_ENV => SIDECAR_URL) do
      controller = controller_for(@user)
      assert controller.select_devices([ device.id ]).ok?
      assert controller.play(song_id: @local_song.id).ok?

      result = controller.dispatch_audio(credentials: { device.id => "hunter2" })

      assert result.ok?, "expected dispatch with a supplied credential to succeed"
    end

    assert_requested :post, PLAY_ENDPOINT do |req|
      JSON.parse(req.body).dig("credentials", device.id.to_s) == "hunter2"
    end
  end

  test "rejects dispatch with an authentication error when the sidecar reports an incorrect credential (Req 14.8)" do
    device = airplay_device(identifier: "locked-office", requires_password: true)
    stub_request(:post, PLAY_ENDPOINT).to_return(status: 401, body: { error: "bad_password" }.to_json)

    with_env(PlaybackSidecar::SIDECAR_URL_ENV => SIDECAR_URL) do
      controller = controller_for(@user)
      assert controller.select_devices([ device.id ]).ok?
      assert controller.play(song_id: @local_song.id).ok?

      result = controller.dispatch_audio(credentials: { device.id => "wrong-password" })

      assert result.rejected?
      assert_equal :device_authentication_error, result.error
    end

    assert_requested :post, PLAY_ENDPOINT
  end

  # --- Dispatch boundary guards / sidecar smoke ------------------------------

  test "rejects dispatch when the session has no active output device (Req 14.14 boundary)" do
    stub_play_ok

    with_env(PlaybackSidecar::SIDECAR_URL_ENV => SIDECAR_URL) do
      controller = controller_for(@user)
      controller.session.update!(current_song_id: @local_song.id, state: "stopped")

      result = controller.dispatch_audio

      assert result.rejected?
      assert_equal :no_output_device, result.error
    end

    assert_not_requested :post, PLAY_ENDPOINT
  end

  test "degrades to a sidecar_unavailable failure when the sidecar is unreachable (Req 14 smoke)" do
    device = airplay_device(identifier: "living-room")
    stub_request(:post, PLAY_ENDPOINT).to_raise(Errno::ECONNREFUSED)

    with_env(PlaybackSidecar::SIDECAR_URL_ENV => SIDECAR_URL) do
      controller = controller_for(@user)
      assert controller.select_devices([ device.id ]).ok?
      assert controller.play(song_id: @local_song.id).ok?

      result = controller.dispatch_audio

      assert result.rejected?
      assert_equal :sidecar_unavailable, result.error
    end
  end
end
