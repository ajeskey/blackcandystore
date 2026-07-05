# frozen_string_literal: true

require "test_helper"

# Property-based test for Property 15 of the multi-server-library-sharing
# feature.
#
# Design property (multi-server-library-sharing, Property 15):
#   For any Playlist containing a mix of local and remote Songs, the returned
#   Playlist SHALL preserve the original order and membership, resolve each
#   Song's `stream_source` and `resolved_stream_path` independently according to
#   that Song's own Library, and set only the unavailable Songs'
#   `resolved_stream_path` to empty while leaving every other Song's resolution
#   unchanged; the Playlist response SHALL never be rejected as a whole.
#
# This exercises the actual serialization path used by the player/API:
# `SongHelper#song_json_builder` (which resolves each Song through
# `PathResolver`) is mapped in order over a real `Playlist`'s songs. Songs are
# pushed onto the Playlist so that `playlist.songs` reflects the persisted
# order/membership.
#
# Each generated Playlist mixes songs drawn randomly from these categories:
#   * :local              - a Song in a Local_Library on this server (available)
#   * :remote_active      - a Song in a Remote_Library reached through an
#                           *active* Library_Connection (available, Req 8.5)
#   * :remote_revoked     - a Remote_Library whose connection is revoked
#                           (unavailable, Req 10.4)
#   * :remote_unavailable - a Remote_Library whose connection is unavailable
#                           (unavailable, Req 10.5)
#   * :remote_no_conn     - a Remote_Library with no Library_Connection at all
#                           (unavailable)
#
# For each generated Playlist it asserts:
#   (Req 10.6) the serialized order and membership equal the input order/
#              membership (each song stays in its position, including
#              unavailable ones);
#   (Req 10.3) each song is resolved independently per its own library
#              (stream_source matches the song's own category);
#   (Req 10.5/10.7) available songs (local + reachable remote) have a non-empty
#              resolved_stream_path and available == true;
#   (Req 10.4/10.7) only unavailable songs have an empty resolved_stream_path
#              and available == false;
#   (Req 10.8) the whole playlist is always produced (never rejected/dropped),
#              even when it contains unavailable songs.
class PlaylistResolutionPropertyTest < ActionView::TestCase
  include Rails.application.routes.url_helpers
  include ApplicationHelper
  include SongHelper

  CATEGORIES = %i[local remote_active remote_revoked remote_unavailable remote_no_conn].freeze
  AVAILABLE_CATEGORIES = %i[local remote_active].freeze

  setup do
    @seq = 0
    @user = users(:visitor1)
    # `Current.user` delegates to `Current.session`; song_json_builder uses it
    # for the favorite lookup.
    Current.session = Session.new(user: @user)
    @transcode = false

    # One shared library per category so each iteration only creates songs.
    media_path = Rails.root.join("test", "fixtures", "files").to_s
    @libraries = {
      local: Library.create!(
        name: "Prop15-Local-#{SecureRandom.hex(4)}",
        kind: :local,
        owner: @user,
        media_path: media_path
      ),
      remote_active: remote_library(:active),
      remote_revoked: remote_library(:revoked),
      remote_unavailable: remote_library(:unavailable),
      # A Remote_Library with no Library_Connection cannot be resolved.
      remote_no_conn: Library.create!(
        name: "Prop15-RemoteNoConn-#{SecureRandom.hex(4)}",
        kind: :remote,
        owner: @user,
        library_connection: nil
      )
    }
  end

  teardown do
    Current.session = nil
  end

  # The helper calls `need_transcode?(song)`; provide it in the view context.
  def need_transcode?(_song)
    @transcode
  end

  # Feature: multi-server-library-sharing, Property 15: Playlist resolution preserves order and membership and resolves each song independently
  test "playlist resolution preserves order and membership and resolves each song independently" do
    check_property(iterations: 100) do
      # Generate an ORDERED sequence of 1..8 songs, each a random category so a
      # playlist can mix local, reachable-remote, and unavailable-remote songs.
      length = range(1, 8)
      Array.new(length) { CATEGORIES[range(0, CATEGORIES.length - 1)] }
    end.check do |categories|
      # Build a real Playlist and push songs in order to fix order/membership.
      playlist = Playlist.create!(name: "Prop15-Playlist-#{next_seq}", user: @user)
      input_songs = categories.map { |category| build_song(category) }
      input_songs.each { |song| playlist.songs.push(song) }

      ordered_songs = playlist.songs.to_a

      # (Req 10.8) The whole playlist is always produced and serialized -- no
      # song is dropped and the response is never rejected, even when it
      # contains unavailable remote songs.
      serialized = ordered_songs.map { |song| JSON.parse(song_json_builder(song).target!) }
      assert_equal categories.length, serialized.length,
        "expected every playlist song to be serialized (playlist never rejected)"

      # (Req 10.6) Order and membership are preserved: the serialized song ids
      # match the input song ids in the same positions.
      assert_equal input_songs.map(&:id), serialized.map { |entry| entry["id"] },
        "expected serialized order/membership to equal the input playlist"

      # Independent, per-song resolution (Req 10.3, 10.4, 10.5, 10.7).
      categories.each_with_index do |category, index|
        entry = serialized[index]

        expected_source = (category == :local) ? "local" : "remote"
        assert_equal expected_source, entry["stream_source"],
          "expected #{category} song at position #{index} to classify as #{expected_source}"

        if AVAILABLE_CATEGORIES.include?(category)
          # (Req 10.5, 10.7) Available songs resolve to a non-empty path.
          assert entry["available"],
            "expected available #{category} song at position #{index} to be available"
          assert entry["resolved_stream_path"].present?,
            "expected available #{category} song at position #{index} to have a non-empty path"
        else
          # (Req 10.4, 10.7) Only unavailable songs are emptied.
          assert_not entry["available"],
            "expected unavailable #{category} song at position #{index} to be unavailable"
          assert_equal "", entry["resolved_stream_path"],
            "expected unavailable #{category} song at position #{index} to have an empty path"
        end
      end

      # Independence check (Req 10.3): the set of emptied songs is exactly the
      # set of unavailable-category songs -- an unavailable song never empties a
      # neighboring available song's resolution.
      emptied_positions = serialized.each_index.select { |i| serialized[i]["resolved_stream_path"] == "" }
      expected_emptied = categories.each_index.reject { |i| AVAILABLE_CATEGORIES.include?(categories[i]) }
      assert_equal expected_emptied, emptied_positions,
        "expected only unavailable songs to be emptied, leaving other songs unchanged"
    end
  end

  private

  def next_seq
    @seq += 1
  end

  def remote_library(connection_status)
    connection = LibraryConnection.create!(
      user: @user,
      server_base_url: "https://remote-#{connection_status}.example.com",
      remote_library_id: range_seed,
      grant_token: "remote-bearer-token-#{connection_status}",
      status: connection_status
    )
    Library.create!(
      name: "Prop15-Remote-#{connection_status}-#{SecureRandom.hex(4)}",
      kind: :remote,
      owner: @user,
      library_connection: connection
    )
  end

  # Unique remote_library_id for the (user, server_base_url, remote_library_id)
  # index across the setup connections.
  def range_seed
    @range_seed = (@range_seed || 4200) + 1
  end

  # Build a persisted Song under the shared library implied by `category`.
  def build_song(category)
    library = @libraries[category]

    n = next_seq
    artist = Artist.create!(name: "Prop15-Artist-#{n}", library: library)
    album = Album.create!(name: "Prop15-Album-#{n}", artist: artist, library: library)
    Song.create!(
      name: "Prop15-Song-#{n}",
      file_path: "/tmp/prop15-song-#{n}.mp3",
      file_path_hash: "prop15-fph-#{SecureRandom.hex(8)}",
      md5_hash: "prop15-md5-#{SecureRandom.hex(8)}",
      library: library,
      album: album,
      artist: artist
    )
  end
end
