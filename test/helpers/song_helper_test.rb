# frozen_string_literal: true

require "test_helper"

class SongHelperTest < ActionView::TestCase
  include Rails.application.routes.url_helpers
  include ApplicationHelper

  setup do
    @user = users(:visitor1)
    # `Current.user` delegates to `Current.session`; set a session so the
    # helper's favorite lookup resolves to the user.
    Current.session = Session.new(user: @user)
    # `need_transcode?` normally lives in the request layer (ClientDetection);
    # the helper only consumes its boolean result, so we control it here.
    @transcode = false
  end

  teardown do
    Current.session = nil
  end

  # The helper calls `need_transcode?(song)`; provide it in the view context.
  def need_transcode?(_song)
    @transcode
  end

  test "adds stream_source and resolved_stream_path for a local song while keeping url (Req 8.3, 8.10)" do
    song = songs(:mp3_sample)

    json = JSON.parse(song_json_builder(song).target!)

    # Backward-compatible `url` field is unchanged (full stream URL).
    assert_equal new_stream_url(song_id: song.id), json["url"]
    # New resolved fields resolve to a same-origin path on the current server.
    assert_equal "local", json["stream_source"]
    assert_equal new_stream_path(song_id: song.id), json["resolved_stream_path"]
    assert json["available"]
    assert json["resolved_stream_path"].present?
  end

  test "uses the transcoded path for resolved_stream_path when transcoding is required" do
    @transcode = true
    song = songs(:mp3_sample)

    json = JSON.parse(song_json_builder(song).target!)

    assert_equal new_transcoded_stream_url(song_id: song.id), json["url"]
    assert_equal "local", json["stream_source"]
    assert_equal new_transcoded_stream_path(song_id: song.id), json["resolved_stream_path"]
  end

  test "classifies a remote song and resolves a same-origin proxy path (Req 8.3)" do
    song = remote_song(connection_status: :active)

    json = JSON.parse(song_json_builder(song).target!)

    assert_equal "remote", json["stream_source"]
    assert_equal "/stream/remote/#{song.id}", json["resolved_stream_path"]
    assert json["available"]
    # The legacy `url` field is preserved unchanged for backward compatibility.
    assert_equal new_stream_url(song_id: song.id), json["url"]
  end

  test "marks an unresolvable remote song unavailable with an empty resolved path (Req 8.11)" do
    song = remote_song(connection_status: :revoked)

    json = JSON.parse(song_json_builder(song).target!)

    assert_equal "remote", json["stream_source"]
    assert_equal "", json["resolved_stream_path"]
    assert_not json["available"]
    # Other attributes are preserved unchanged.
    assert_equal song.name, json["name"]
    assert_equal song.duration, json["duration"]
  end

  private

  def remote_song(connection_status:)
    connection = LibraryConnection.create!(
      user: @user,
      server_base_url: "https://remote.example.com",
      remote_library_id: 99,
      grant_token: "remote-bearer-token",
      status: connection_status
    )
    library = Library.create!(
      name: "Remote Library #{SecureRandom.hex(4)}",
      kind: :remote,
      owner: @user,
      library_connection: connection
    )

    song = songs(:flac_sample)
    song.update_columns(library_id: library.id)
    song.reload
  end
end
