# frozen_string_literal: true

require "test_helper"

# Covers the additive, signed-token authentication path used by the playback
# sidecar to fetch a Song's audio without a login session (SidecarStreamAccess).
class SidecarStreamAccessTest < ActionDispatch::IntegrationTest
  setup do
    @song = songs(:mp3_sample)
  end

  def stream_token(song, purpose: PlaybackController::SIDECAR_STREAM_PURPOSE, expires_in: 1.hour)
    song.signed_id(purpose: purpose, expires_in: expires_in)
  end

  test "a valid sidecar stream token authorizes the fetch without a login session" do
    get new_stream_url(song_id: @song.id, stream_token: stream_token(@song))

    assert_response :success
    assert_equal binary_data(file_fixture("artist1_album2.mp3")), response.body
  end

  test "a request with no token and no session is not authorized" do
    get new_stream_url(song_id: @song.id)

    assert_redirected_to new_session_path
  end

  test "a token issued for a different song is rejected" do
    other_song = songs(:flac_sample)

    get new_stream_url(song_id: @song.id, stream_token: stream_token(other_song))

    assert_redirected_to new_session_path
  end

  test "a token minted for a different purpose is rejected" do
    get new_stream_url(song_id: @song.id, stream_token: stream_token(@song, purpose: :something_else))

    assert_redirected_to new_session_path
  end

  test "an expired token is rejected" do
    token = stream_token(@song, expires_in: 1.second)

    travel 2.seconds do
      get new_stream_url(song_id: @song.id, stream_token: token)
    end

    assert_redirected_to new_session_path
  end

  test "the transcoded stream endpoint also honors a valid sidecar token" do
    get new_transcoded_stream_url(song_id: @song.id, stream_token: stream_token(@song))

    assert_response :success
  end
end
