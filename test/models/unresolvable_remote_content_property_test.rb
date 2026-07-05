# frozen_string_literal: true

require "test_helper"

# Property-based test for Property 13 of the multi-server-library-sharing
# feature.
#
# Design property (multi-server-library-sharing, Property 13):
#   For any Song whose `stream_source` is `remote` and whose Library_Connection
#   cannot be resolved to a streaming endpoint, the Server SHALL set its
#   `resolved_stream_path` to empty, mark it unavailable, and preserve all of
#   the Song's other attributes unchanged. The analogous rule SHALL hold for a
#   Displayable_Asset (an Album's or Artist's cover image) whose owning
#   content's Library_Connection cannot be resolved (Req 8.11, 9.8).
#
# A Library_Connection "cannot be resolved to an endpoint" when it is missing
# entirely, revoked, or unavailable. This test generates remote Songs, Albums,
# and Artists across all three unresolvable connection states and, for each,
# snapshots the record's other attributes, invokes the PathResolver, then
# asserts:
#   * the resolved path is empty,
#   * the record is marked unavailable, and
#   * every other attribute of the record is unchanged.
class UnresolvableRemoteContentPropertyTest < ActiveSupport::TestCase
  UNRESOLVABLE_STATES = %i[none revoked unavailable].freeze
  CONTENT_KINDS = %i[song album artist].freeze

  setup do
    @resolver = PathResolver.new
    @user = users(:visitor1)
  end

  # Feature: multi-server-library-sharing, Property 13: Unresolvable remote content yields an empty path and preserves other attributes
  test "unresolvable remote content yields an empty path, is unavailable, and preserves other attributes" do
    check_property(iterations: 100) do
      # Describe one remote record whose connection cannot be resolved. We pick
      # the content kind, the unresolvable connection state, and randomized
      # attribute values so the property is exercised across the full input
      # space (songs and cover-image assets, every unresolvable state, varied
      # attributes).
      kind = CONTENT_KINDS[range(0, CONTENT_KINDS.size - 1)]
      connection_state = UNRESOLVABLE_STATES[range(0, UNRESOLVABLE_STATES.size - 1)]

      attrs = {
        name: sized(range(1, 24)) { string(:alpha) },
        duration: range(0, 6000).to_f,
        tracknum: range(1, 40),
        discnum: range(1, 5),
        year: range(1900, 2100),
        genre: sized(range(0, 12)) { string(:alpha) },
        various: boolean,
        variant: %i[small medium large][range(0, 2)]
      }

      [ kind, connection_state, attrs ]
    end.check do |(kind, connection_state, attrs)|
      record = build_remote_record(kind, connection_state, attrs)

      # Snapshot every persisted attribute so we can prove the resolver mutates
      # none of them.
      attributes_before = record.attributes.deep_dup

      result =
        if kind == :song
          @resolver.resolve_stream(record, user: @user)
        else
          @resolver.resolve_asset(record, user: @user, variant: attrs[:variant])
        end

      path_key = kind == :song ? :resolved_stream_path : :resolved_asset_path

      assert_equal "", result[path_key],
        "expected an empty path for an unresolvable remote #{kind} (state=#{connection_state}), got #{result[path_key].inspect}"
      assert_equal false, result[:available],
        "expected an unresolvable remote #{kind} (state=#{connection_state}) to be marked unavailable"

      assert_equal attributes_before, record.attributes,
        "resolving an unresolvable remote #{kind} (state=#{connection_state}) changed its attributes: " \
        "#{diff_attributes(attributes_before, record.attributes)}"
    end
  end

  private

  # A remote Library reached through a Library_Connection that cannot be
  # resolved to an endpoint: either no connection at all (`:none`) or a
  # connection in a `revoked` / `unavailable` status.
  def build_remote_record(kind, connection_state, attrs)
    library = create_remote_library(connection_state)

    case kind
    when :song
      artist = Artist.create!(name: unique_name(attrs[:name]), library: library)
      album = Album.create!(name: unique_name(attrs[:name]), artist: artist, library: library, year: attrs[:year], genre: attrs[:genre])
      Song.create!(
        name: attrs[:name].presence || "Song",
        file_path: "/remote/#{SecureRandom.hex(8)}.mp3",
        file_path_hash: SecureRandom.hex(8),
        md5_hash: SecureRandom.hex(8),
        duration: attrs[:duration],
        tracknum: attrs[:tracknum],
        discnum: attrs[:discnum],
        library: library,
        album: album,
        artist: artist
      ).reload
    when :album
      artist = Artist.create!(name: unique_name(attrs[:name]), library: library)
      Album.create!(
        name: attrs[:name].presence || "Album",
        artist: artist,
        library: library,
        year: attrs[:year],
        genre: attrs[:genre]
      ).reload
    when :artist
      Artist.create!(
        name: attrs[:name].presence || "Artist",
        library: library,
        various: attrs[:various]
      ).reload
    end
  end

  def create_remote_library(connection_state)
    Library.create!(
      name: "Remote Library #{SecureRandom.hex(6)}",
      kind: :remote,
      owner: @user,
      library_connection: remote_connection(connection_state)
    )
  end

  # `:none` models a Remote_Library with no Library_Connection at all; the other
  # states model a connection that exists but cannot be resolved to an endpoint.
  def remote_connection(connection_state)
    return nil if connection_state == :none

    LibraryConnection.create!(
      user: @user,
      server_base_url: "https://remote.example.com",
      remote_library_id: next_remote_library_id,
      grant_token: "remote-bearer-token",
      status: connection_state
    )
  end

  # Names only need to be unique within a freshly created library, but the
  # generator can produce an empty string, so fall back to a random token.
  def unique_name(seed)
    base = seed.presence || "n"
    "#{base}-#{SecureRandom.hex(4)}"
  end

  def next_remote_library_id
    @next_remote_library_id ||= 0
    @next_remote_library_id += 1
  end

  def diff_attributes(before, after)
    before.each_with_object({}) do |(key, value), diff|
      diff[key] = [ value, after[key] ] if after[key] != value
    end
  end
end
