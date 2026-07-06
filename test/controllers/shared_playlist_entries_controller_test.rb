# frozen_string_literal: true

require "test_helper"

# Happy-path coverage for the Shared_Playlist contribution surface (task 8.9)
# from the HOST side: the Host adds, lists, reorders, and removes entries of a
# session's Shared_Playlist through the client-agnostic JSON representation
# (Req 5.2, 6.3, 6.6, 9.1, 9.4). The Guest side is exercised end-to-end in
# test/integration/guest_admission_flow_test.rb.
class SharedPlaylistEntriesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @host = users(:visitor1)
    @library = libraries(:default_library)
    @song = songs(:mp3_sample)
    @other_song = songs(:flac_sample)

    @session = PartySession.create!(
      user: @host,
      session_duration_kind: "perpetual",
      duplicate_policy: "allow",
      shared_library_ids: [ @library.id ]
    )
    @shared_playlist = SharedPlaylist.create!(sessionable: @session)
  end

  def host_add!(song)
    SharedPlaylistAddService.call(shared_playlist: @shared_playlist, song_id: song.id, host: @host)
  end

  test "host adds a song to the shared playlist (Req 5.2, 6.6)" do
    assert_difference -> { @shared_playlist.entries.count }, 1 do
      post shared_playlist_shared_playlist_entries_url(@shared_playlist),
        params: { song_id: @song.id },
        as: :json,
        headers: api_token_header(@host)
    end

    assert_response :created
    body = @response.parsed_body
    assert_equal @song.id, body["song_id"]
    # A host add is attributed to the host, not a guest (Req 5.12).
    assert_equal @host.id, body["added_by_user_id"]
    assert_nil body["added_by_guest_id"]
  end

  test "index lists the shared playlist entries in order (Req 6.3)" do
    first = host_add!(@song)
    second = host_add!(@other_song)

    get shared_playlist_shared_playlist_entries_url(@shared_playlist),
      as: :json,
      headers: api_token_header(@host)

    assert_response :ok
    body = @response.parsed_body
    assert_equal @shared_playlist.id, body["shared_playlist_id"]
    assert_equal [ first.id, second.id ], body["entries"].map { |e| e["id"] }
  end

  test "host reorders an entry (Req 6.6)" do
    first = host_add!(@song)
    second = host_add!(@other_song)

    patch shared_playlist_shared_playlist_entry_url(@shared_playlist, second),
      params: { position: 1 },
      as: :json,
      headers: api_token_header(@host)

    assert_response :ok
    assert_equal 1, second.reload.position
    assert_equal 2, first.reload.position
  end

  test "host removes an entry (Req 6.6)" do
    entry = host_add!(@song)

    assert_difference -> { @shared_playlist.entries.count }, -1 do
      delete shared_playlist_shared_playlist_entry_url(@shared_playlist, entry),
        as: :json,
        headers: api_token_header(@host)
    end

    assert_response :no_content
  end
end
