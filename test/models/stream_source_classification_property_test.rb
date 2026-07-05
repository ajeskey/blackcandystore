# frozen_string_literal: true

require "test_helper"

# Property-based test for Property 12 of the multi-server-library-sharing
# feature.
#
# Design property (multi-server-library-sharing, Property 12):
#   For any Song returned to the Web_Player or App_Player, the response SHALL
#   include a `stream_source` of `local` when the Song's Library is a
#   Local_Library (including the Default_Library and any Song whose Library
#   association cannot be determined) or `remote` when it is a Remote_Library,
#   and when resolution succeeds the `resolved_stream_path` SHALL be non-empty
#   and point to the current Server for `local` sources and to the hosting
#   Server's derived endpoint for `remote` sources.
#
# This exercises PathResolver#resolve_stream across four generated library
# situations:
#   * :local   - a Song in a non-default Local_Library on this server
#   * :default - a Song in the Default_Library (also local, Req 8.8)
#   * :nil     - a Song whose Library association cannot be determined (Req 8.9)
#   * :remote  - a Song in a Remote_Library reached through an *active*
#                Library_Connection (Req 8.5)
#
# For each generated Song (and a generated transcode flag) it asserts:
#   (classification) stream_source is "local" for local/default/nil sources and
#                    "remote" for the remote source (Req 8.1, 8.4, 8.9, 8.10);
#   (resolution)     when resolution succeeds the resolved_stream_path is
#                    non-empty and points at the correct server -- the
#                    current-server new_stream_path/new_transcoded_stream_path
#                    for local sources (Req 8.3, 8.4) and the same-origin
#                    /stream/remote/:song_id proxy path for remote sources
#                    (Req 8.5).
class StreamSourceClassificationPropertyTest < ActiveSupport::TestCase
  include Rails.application.routes.url_helpers

  CATEGORIES = %i[local default nil remote].freeze

  setup do
    @seq = 0
    @resolver = PathResolver.new
    @user = users(:visitor1)

    # The Default_Library is the pre-existing local collection (Req 8.8).
    @default_library = libraries(:default_library)

    # A non-default Local_Library on the current server (Req 8.1, 8.4). Its
    # media_path must exist and be readable to satisfy Library validation.
    @local_library = Library.create!(
      name: "Prop12-Local-#{SecureRandom.hex(4)}",
      kind: :local,
      owner: @user,
      media_path: Rails.root.join("test", "fixtures", "files").to_s
    )

    # A Remote_Library reached through an *active* Library_Connection so remote
    # stream resolution succeeds (Req 8.5).
    connection = LibraryConnection.create!(
      user: @user,
      server_base_url: "https://remote.example.com",
      remote_library_id: 4242,
      grant_token: "remote-bearer-token",
      status: :active
    )
    @remote_library = Library.create!(
      name: "Prop12-Remote-#{SecureRandom.hex(4)}",
      kind: :remote,
      owner: @user,
      library_connection: connection
    )
  end

  # Feature: multi-server-library-sharing, Property 12: Stream-source classification and resolution are consistent
  test "stream-source classification and successful resolution are consistent across local, default, nil, and remote libraries" do
    check_property(iterations: 100) do
      # Generate one library situation and a transcode flag per iteration.
      category = CATEGORIES[range(0, CATEGORIES.length - 1)]
      transcode = boolean
      [ category, transcode ]
    end.check do |(category, transcode)|
      song = build_song(category)

      result = @resolver.resolve_stream(song, user: @user, transcode: transcode)

      case category
      when :remote
        # A Remote_Library Song is classified remote and, with an active
        # connection, resolves to the same-origin proxy endpoint on the current
        # server that maps to the hosting server (Req 8.1, 8.5, 8.10).
        assert_equal "remote", result[:stream_source],
          "expected remote stream_source for a remote-library song"
        assert result[:available], "expected an active-connection remote song to resolve"
        assert_not_empty result[:resolved_stream_path],
          "expected a non-empty resolved_stream_path for a resolvable remote song"
        assert_equal "/stream/remote/#{song.id}", result[:resolved_stream_path],
          "expected the remote proxy path to point at the derived hosting endpoint"
      else
        # Local, Default_Library, and undeterminable-association songs are all
        # classified local and resolve to the current-server stream path
        # (Req 8.1, 8.4, 8.8, 8.9).
        assert_equal "local", result[:stream_source],
          "expected local stream_source for #{category} library song"
        assert result[:available], "expected a local song to resolve"
        assert_not_empty result[:resolved_stream_path],
          "expected a non-empty resolved_stream_path for a local song"

        expected_path =
          if transcode
            new_transcoded_stream_path(song_id: song.id)
          else
            new_stream_path(song_id: song.id)
          end
        assert_equal expected_path, result[:resolved_stream_path],
          "expected the current-server stream path for a #{category} library song"
      end
    end
  end

  private

  def next_seq
    @seq += 1
  end

  # Build a persisted Song under the library implied by `category`. For the
  # :nil case the Song is created under a local library (the not-null
  # library_id constraint forbids persisting a null association) and then has
  # its association detached in memory, modeling a Song whose Library cannot be
  # determined at resolution time (Req 8.9).
  def build_song(category)
    library =
      case category
      when :local   then @local_library
      when :default then @default_library
      when :remote  then @remote_library
      when :nil     then @local_library
      end

    n = next_seq
    artist = Artist.create!(name: "Prop12-Artist-#{n}", library: library)
    album = Album.create!(name: "Prop12-Album-#{n}", artist: artist, library: library)
    song = Song.create!(
      name: "Prop12-Song-#{n}",
      file_path: "/tmp/prop12-song-#{n}.mp3",
      file_path_hash: "prop12-fph-#{SecureRandom.hex(8)}",
      md5_hash: "prop12-md5-#{SecureRandom.hex(8)}",
      library: library,
      album: album,
      artist: artist
    )

    song.library = nil if category == :nil
    song
  end
end
