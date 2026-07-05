# frozen_string_literal: true

require "test_helper"

# Property-based test for Property 14 of the remote-library-mirror-sync feature.
#
# Design property (remote-library-mirror-sync, Property 14):
#   For any Mirrored_Song, Path_Resolver SHALL classify its Stream_Source as
#   `remote`, and when its Library_Connection is active SHALL produce a
#   Resolved_Stream_Path through the same-origin remote-stream proxy; the audio
#   fetch for that Mirrored_Song SHALL be keyed on the pairing of the
#   Library_Connection and the stored Remote_Song_Id (Req 7.1, 7.5).
#
# A Mirrored_Song is an ordinary Song row in a `kind: remote` Library that has a
# Library_Connection and carries the hosting-side id in `songs.remote_song_id`.
# This test generates Mirrored_Songs across the three connection states a
# Library_Connection can hold (`active`, `revoked`, `unavailable`) with a
# randomized, deliberately-distinct Remote_Song_Id per song, then asserts:
#
#   (classification) PathResolver#resolve_stream classifies every Mirrored_Song
#                    as `remote` regardless of connection state (Req 7.5);
#   (resolution)     when the connection is `active`, the resolved path is the
#                    same-origin `/stream/remote/:song_id` proxy path and the
#                    song is available; when it is not active, the path is empty
#                    and the song is unavailable (Req 7.5, 11.3);
#   (keying)         the audio fetch is keyed on the pairing of the
#                    Library_Connection and the stored Remote_Song_Id — the
#                    remote-stream proxy translates the local Song to its
#                    hosting-side id (`song.remote_song_id`, distinct from the
#                    local `song.id`) and reaches the host through the song's
#                    `library.library_connection` (Req 7.1, 7.2).
class RemoteClassificationStreamKeyingPropertyTest < ActiveSupport::TestCase
  CONNECTION_STATES = %i[active revoked unavailable].freeze

  # A Remote_Song_Id is the hosting-side id, which is distinct from the local
  # Song#id. Generating hosting ids in a high band keeps them separate from the
  # small autoincrement ids the redeeming server assigns, so the keying
  # assertion proves the proxy uses the stored hosting id and not the local id.
  REMOTE_ID_BASE = 1_000_000

  setup do
    @resolver = PathResolver.new
    @controller = RemoteStreamController.new
    @user = users(:visitor1)
    @remote_library_seq = 0
  end

  # Feature: remote-library-mirror-sync, Property 14: Mirrored songs classify as remote and resolve through the same-origin proxy keyed on the hosting id
  test "mirrored songs classify as remote, resolve through the same-origin proxy when active, and key the audio fetch on the library connection and stored remote song id" do
    check_property(iterations: 120) do
      # One Mirrored_Song scenario per iteration: its connection state and a
      # hosting-side id distinct from any local id. All DB work happens in the
      # assertion block.
      connection_state = CONNECTION_STATES[range(0, CONNECTION_STATES.size - 1)]
      remote_song_id = REMOTE_ID_BASE + range(1, 5_000_000)
      transcode = boolean

      [ connection_state, remote_song_id, transcode ]
    end.check do |(connection_state, remote_song_id, transcode)|
      song = build_mirrored_song(connection_state, remote_song_id)
      connection = song.library.library_connection

      result = @resolver.resolve_stream(song, user: @user, transcode: transcode)

      # (classification) A Mirrored_Song always classifies as remote because it
      # lives in a `kind: remote` Library, regardless of connection state
      # (Req 7.5).
      assert_equal "remote", result[:stream_source],
        "expected remote stream_source for a mirrored song (state=#{connection_state})"

      if connection_state == :active
        # (resolution) An active connection resolves to the same-origin
        # remote-stream proxy path keyed on the local song id in the URL, which
        # RemoteStreamController maps to the hosting endpoint (Req 7.5).
        assert result[:available],
          "expected an active-connection mirrored song to resolve"
        assert_equal "/stream/remote/#{song.id}", result[:resolved_stream_path],
          "expected the same-origin remote-stream proxy path for an active mirrored song"
      else
        # A non-active connection cannot be resolved to an endpoint: empty path,
        # unavailable — consistent with remote-source availability (Req 11.3).
        assert_equal false, result[:available],
          "expected a non-active mirrored song (state=#{connection_state}) to be unavailable"
        assert_equal "", result[:resolved_stream_path],
          "expected an empty resolved_stream_path for a non-active mirrored song (state=#{connection_state})"
      end

      # (keying) The audio fetch is keyed on the pairing of the
      # Library_Connection and the stored Remote_Song_Id. The proxy translates
      # the local Song to its hosting-side id and reaches the host through the
      # song's own library connection (Req 7.1, 7.2).
      assert_equal song.remote_song_id, @controller.send(:remote_song_id, song),
        "the proxy must key the fetch on the stored hosting-side remote_song_id"
      assert_not_equal song.id, @controller.send(:remote_song_id, song),
        "the hosting-side remote_song_id must be distinct from the local song id"
      assert_equal connection, @controller.send(:remote_connection_for, song),
        "the proxy must reach the host through the song's own library connection"
      assert_not_nil connection.remote_library_id,
        "the connection must carry the remote_library_id the fetch pairs with the remote_song_id"
    end
  end

  private

  # Create an active/revoked/unavailable Library_Connection, a `kind: remote`
  # Library reached through it, and a Mirrored_Song (metadata-only, no file)
  # carrying the given hosting-side id. Returns the reloaded song.
  def build_mirrored_song(connection_state, remote_song_id)
    @remote_library_seq += 1

    connection = LibraryConnection.create!(
      user: @user,
      server_base_url: "https://host.example.com",
      remote_library_id: @remote_library_seq,
      grant_token: "grant-token-#{@remote_library_seq}",
      status: connection_state
    )
    library = Library.create!(
      name: "Remote Mirror #{@remote_library_seq}",
      kind: :remote,
      owner: @user,
      library_connection: connection
    )

    artist = Artist.create!(
      name: "Artist #{@remote_library_seq}",
      library: library,
      remote_artist_id: REMOTE_ID_BASE + @remote_library_seq
    )
    album = Album.create!(
      name: "Album #{@remote_library_seq}",
      artist: artist,
      library: library,
      remote_album_id: REMOTE_ID_BASE + @remote_library_seq
    )
    # A Mirrored_Song stores no file bytes (metadata-only mirror); the remote
    # library relaxes the file-backed presence validations.
    Song.create!(
      name: "Song #{remote_song_id}",
      duration: 123.0,
      tracknum: 1,
      discnum: 1,
      library: library,
      album: album,
      artist: artist,
      remote_song_id: remote_song_id
    ).reload
  end
end
