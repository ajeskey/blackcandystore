# frozen_string_literal: true

require "test_helper"

# Integration tests for the CLIENT CASTING DEVICE PATH under the `client_cast`
# Playback_Mode (Req 17.3-17.10, plus the Req 17.12 disconnect boundary).
#
# Under `client_cast` the Web_Player/App_Player is the Cast_Client AND the audio
# source: it fetches a Song's audio from the Song's Resolved_Stream_Path and
# streams it directly to a single target Output_Device (Req 17.3, 17.4, 17.15).
# The Server never decodes or sends the cast Song's audio; it only keeps a
# lightweight Cast_Session for bookkeeping (Req 18.2). Because the actual cast
# happens in the browser/native app, this suite covers the part the Server can
# observe: the full request lifecycle through CastSessionsController that mirrors
# the client's cast activity (select target device + current Song -> play ->
# pause -> resume -> stop), driven end-to-end across multiple requests.
#
# The single-action semantics are covered by CastSessionsControllerTest (task
# 25.1) and the state-machine logic by Property 20 (task 24.2). These tests are
# complementary: they drive the whole lifecycle across several requests and
# assert the persisted bookkeeping the Server retains between them.
#
# Out-of-scope / client-side-only aspects (documented, not asserted server-side
# because the Server never touches the audio and the Cast_Session record holds
# no volume / password / error columns — see db/schema.rb cast_sessions):
#   - Req 17.8 (volume): the Cast_Client sets device volume directly; the Server
#     keeps no volume in the Cast_Session, so there is nothing to assert here.
#   - Req 17.9 / 17.10 (AirPlay password prompt + auth error): the Cast_Client
#     collects and validates the device password against the device itself; the
#     Server neither stores a password nor performs the auth. The only server
#     observable is that a Cast_Session may *reference* a password-protected
#     Output_Device as its target — asserted below — with the credential flow
#     handled entirely on the client.
class ClientCastingDevicePathTest < ActionDispatch::IntegrationTest
  setup do
    OutputDevice.delete_all
    CastSession.delete_all
    @user = users(:visitor1)
    @local_song = songs(:mp3_sample)
    @other_song = songs(:flac_sample)
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

  # --- Full happy-path lifecycle: select -> play -> pause -> resume -> stop ---

  test "records a full client-cast lifecycle: select target device and song, play, pause, resume, stop (Req 17.3, 17.5, 17.6, 17.16, 17.7)" do
    device = chromecast_device(identifier: "kitchen")

    # Select the target Output_Device + current Song (Req 17.3: the client will
    # cast that Song to that device). Bookkeeping starts idle/`stopped`.
    post cast_session_url,
      params: { target_output_device_id: device.id, current_song_id: @local_song.id },
      as: :json,
      headers: api_token_header(@user)
    assert_response :created
    assert_equal "stopped", @response.parsed_body["state"]
    assert_equal device.id, @response.parsed_body["target_output_device_id"]
    assert_equal @local_song.id, @response.parsed_body["current_song_id"]

    # Play -> the session is `playing`, targeting the selected device (Req 17.5).
    post play_cast_session_url,
      params: { current_song_id: @local_song.id, position: 0 },
      as: :json,
      headers: api_token_header(@user)
    assert_response :success
    assert_equal "playing", @response.parsed_body["state"]
    assert_equal device.id, @response.parsed_body["target_output_device_id"]

    # Advance the position as the client streams, then pause: song + position are
    # retained (Req 17.6).
    CastSession.find_by!(user: @user).update!(position: 42)
    post pause_cast_session_url, as: :json, headers: api_token_header(@user)
    assert_response :success
    assert_equal "paused", @response.parsed_body["state"]
    assert_equal @local_song.id, @response.parsed_body["current_song_id"]
    assert_equal 42, @response.parsed_body["position"]

    # Resume with no intervening operation -> back to `playing`, same song +
    # position (Req 17.16).
    post resume_cast_session_url, as: :json, headers: api_token_header(@user)
    assert_response :success
    assert_equal "playing", @response.parsed_body["state"]
    assert_equal @local_song.id, @response.parsed_body["current_song_id"]
    assert_equal 42, @response.parsed_body["position"]

    # Stop -> `stopped` and the playback position is cleared (Req 17.7).
    post stop_cast_session_url, as: :json, headers: api_token_header(@user)
    assert_response :success
    assert_equal "stopped", @response.parsed_body["state"]
    assert_equal 0, @response.parsed_body["position"]

    # The persisted bookkeeping reflects the final state.
    session = CastSession.find_by!(user: @user)
    assert_equal "stopped", session.state
    assert_equal 0, session.position
  end

  # --- Req 17.4: a remote-source Song is cast the same way as a local one -----

  test "records a remote Stream_Source Song as the cast target Song, same as a local one (Req 17.4)" do
    device = chromecast_device(identifier: "kitchen")
    connection = LibraryConnection.create!(user: @user, status: :active, grant_token: "secret-token")
    remote_library = Library.create!(name: "Remote Friend Library", kind: :remote, library_connection: connection)
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

    post cast_session_url,
      params: { target_output_device_id: device.id, current_song_id: remote_song.id },
      as: :json,
      headers: api_token_header(@user)
    assert_response :created

    post play_cast_session_url, as: :json, headers: api_token_header(@user)
    assert_response :success

    body = @response.parsed_body
    # The Server records the remote Song exactly like a local one; resolving the
    # Resolved_Stream_Path and streaming it is the Cast_Client's job (Req 17.4).
    assert_equal "playing", body["state"]
    assert_equal remote_song.id, body["current_song_id"]
    assert_equal device.id, body["target_output_device_id"]
  end

  # --- No target device: the client has nothing to cast to --------------------

  test "rejects play when no target Output_Device is selected and leaves the persisted state unchanged (Req 17.5)" do
    # A bookkeeping record exists but no target device was ever selected.
    post cast_session_url,
      params: { current_song_id: @local_song.id },
      as: :json,
      headers: api_token_header(@user)
    assert_response :created
    assert_nil @response.parsed_body["target_output_device_id"]

    post play_cast_session_url, as: :json, headers: api_token_header(@user)
    assert_response :unprocessable_entity
    assert_equal "CastTransitionRejected", @response.parsed_body["type"]

    assert_equal "stopped", CastSession.find_by!(user: @user).state
  end

  test "rejects resume when no target Output_Device is selected and leaves the persisted state unchanged (Req 17.16)" do
    # Paused but the target device is gone: resume has nothing to cast to.
    CastSession.create!(
      user: @user,
      target_output_device_id: nil,
      state: "paused",
      current_song_id: @local_song.id,
      position: 15
    )

    post resume_cast_session_url, as: :json, headers: api_token_header(@user)
    assert_response :unprocessable_entity
    assert_equal "CastTransitionRejected", @response.parsed_body["type"]

    session = CastSession.find_by!(user: @user)
    assert_equal "paused", session.state
    assert_equal 15, session.position
  end

  # --- Req 17.12 boundary: target device disconnects while playing ------------
  #
  # The disconnect itself is detected on the client (the Cast_Client loses the
  # device), so there is no HTTP action for it; the Server-side bookkeeping is
  # the CastSession#output_device_unavailable transition, exercised here after
  # driving the session into `playing` through the real request lifecycle.
  test "stops the cast session when the target Output_Device becomes unavailable while playing (Req 17.12)" do
    device = airplay_device(identifier: "living-room")

    post cast_session_url,
      params: { target_output_device_id: device.id, current_song_id: @local_song.id },
      as: :json,
      headers: api_token_header(@user)
    post play_cast_session_url, as: :json, headers: api_token_header(@user)
    assert_response :success
    assert_equal "playing", @response.parsed_body["state"]

    session = CastSession.find_by!(user: @user)
    assert session.output_device_unavailable(device.id), "expected the disconnect to apply while playing"
    session.save!

    session.reload
    assert_equal "stopped", session.state
    assert_equal 0, session.position

    # A different device disconnecting, or a disconnect while not playing, is a
    # no-op (only the last active target matters).
    assert_not session.output_device_unavailable(device.id)
  end

  # --- Req 17.9 / 17.10: password-protected device is client-side only --------

  test "a cast session may target a password-protected AirPlay device; the credential flow is client-side (Req 17.9, 17.10)" do
    locked = airplay_device(identifier: "locked-office", requires_password: true)

    post cast_session_url,
      params: { target_output_device_id: locked.id, current_song_id: @local_song.id },
      as: :json,
      headers: api_token_header(@user)
    assert_response :created

    # The only server observable is the target reference; there is no password or
    # auth state on the Cast_Session (the Cast_Client prompts for and validates
    # the AirPlay password directly against the device — Req 17.9, 17.10).
    session = CastSession.find_by!(user: @user)
    assert_equal locked.id, session.target_output_device_id
    assert OutputDevice.find(session.target_output_device_id).requires_password
    assert_not session.attributes.key?("device_password")
  end
end
