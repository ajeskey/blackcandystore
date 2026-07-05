# frozen_string_literal: true

require "test_helper"

# Verifies cross-server playlist resolution (Requirement 10): a Playlist may mix
# Songs from local and remote Libraries, each Song's stream source and resolved
# path are resolved independently, only unavailable Songs have an empty path, the
# original order and membership are preserved, and one unavailable Song never
# rejects the whole Playlist response.
class Playlists::MixedSourceResolutionTest < ActionDispatch::IntegrationTest
  setup do
    @playlist = playlists(:playlist1)
    @user = @playlist.user
    login @user
  end

  test "resolves each playlist song independently across servers, preserving order and membership (Req 10.1-10.8)" do
    local_song = songs(:mp3_sample)        # id 1, Default_Library (local)
    local_song2 = songs(:flac_sample)      # id 2, Default_Library (local)
    remote_available = songs(:ogg_sample)  # id 3, moved to an active remote library
    remote_unavailable = songs(:wav_sample) # id 4, moved to a revoked remote library

    # Song 3 lives in a Remote_Library on one hosting server (reachable).
    move_to_remote_library(remote_available, connection_status: :active, remote_library_id: 51)
    # Song 4 lives in a Remote_Library whose access was revoked (unreachable).
    move_to_remote_library(remote_unavailable, connection_status: :revoked, remote_library_id: 52)

    # Build a playlist that mixes local and remote songs from different servers.
    @playlist.songs.clear
    [ local_song, local_song2, remote_available, remote_unavailable ].each do |song|
      @playlist.songs.push(song)
    end

    get playlist_songs_url(@playlist), as: :json, headers: api_token_header(@user)

    # Req 10.8: an unavailable song never rejects the whole playlist response.
    assert_response :success

    body = @response.parsed_body

    # Req 10.6: order and membership are preserved; the unavailable song stays
    # listed in its original position.
    assert_equal [ 1, 2, 3, 4 ], body.map { |song| song["id"] }

    by_id = body.index_by { |song| song["id"] }

    # Req 10.2/10.3: local songs carry a local stream source resolved to a
    # same-origin current-server path.
    [ 1, 2 ].each do |id|
      assert_equal "local", by_id[id]["stream_source"]
      assert by_id[id]["available"]
      assert by_id[id]["resolved_stream_path"].present?, "expected non-empty path for local song #{id}"
    end

    # Req 10.3: the reachable remote song is resolved independently to its own
    # (remote) same-origin proxy path and stays available.
    assert_equal "remote", by_id[3]["stream_source"]
    assert by_id[3]["available"]
    assert_equal "/stream/remote/3", by_id[3]["resolved_stream_path"]

    # Req 10.4/10.7: only the unavailable remote song has an empty resolved path
    # and is marked unavailable; every other song's resolution is unchanged.
    assert_equal "remote", by_id[4]["stream_source"]
    assert_not by_id[4]["available"]
    assert_equal "", by_id[4]["resolved_stream_path"]

    # Req 10.5: songs hosted elsewhere and local songs keep their resolved paths.
    assert by_id[1]["resolved_stream_path"].present?
    assert by_id[2]["resolved_stream_path"].present?
    assert by_id[3]["resolved_stream_path"].present?
  end

  private

  def move_to_remote_library(song, connection_status:, remote_library_id:)
    connection = LibraryConnection.create!(
      user: @user,
      server_base_url: "https://host-#{remote_library_id}.example.com",
      remote_library_id: remote_library_id,
      grant_token: "grant-token-#{remote_library_id}",
      status: connection_status
    )

    library = Library.create!(
      name: "Remote Library #{remote_library_id}",
      kind: :remote,
      owner: @user,
      library_connection: connection
    )

    song.update_columns(library_id: library.id)
    song.reload
  end
end
