# frozen_string_literal: true

require "test_helper"

# Property-based test for Property 12 of the remote-library-mirror-sync feature.
#
# Design property (remote-library-mirror-sync, Property 12):
#   For any Mirrored_Song and any state of its Library_Connection, the
#   Redeeming_Server SHALL treat that Mirrored_Song as available for
#   Source_Preference selection if and only if it is resolvable by
#   Path_Resolver, and while the Library_Connection is not active it SHALL be
#   unavailable for both together; a Mirrored_Song SHALL never be available for
#   one while unavailable for the other (Req 11.2, 11.3).
#
# A Mirrored_Song lives in a Remote_Library whose Library_Connection carries a
# `status` (active|revoked|unavailable). Availability is governed by that
# status: a Mirrored_Song is reachable only while the connection is `active`.
# The connection also carries a SEPARATE `sync_state` column (fresh|stale|
# unavailable). The property mentions a "stale" state; it is modeled as
# `sync_state: stale` while `status` stays `active` — a stale-but-active
# connection is still active, so its Mirrored_Songs remain available. This is
# distinct from a non-active `status`, which makes them unavailable.
#
# For each generated Mirrored_Song the test drives BOTH consumers of the shared
# availability rule:
#   * Source_Preference selection availability — SourcePreference.select over a
#     single-member group returns the Song when it is available for selection
#     and nil when it is not (Req 11.2).
#   * Path_Resolver resolvability — resolve_stream(select_source: false) returns
#     `available: true` when the stream resolves and `false` when it does not.
#     `select_source: false` keeps this a pure per-Song classification so
#     resolution never re-enters selection (Req 11.3).
#
# and asserts:
#   (iff)       selection availability == resolution availability, always; the
#               Mirrored_Song is never available for one while unavailable for
#               the other (Req 11.2, 11.3);
#   (inactive)  while the connection status is not active (revoked/unavailable),
#               BOTH are false together (Req 11.3);
#   (active)    while the connection status is active (including a stale
#               sync_state), BOTH are true together (Req 11.2).
class AvailabilityConsistencyPropertyTest < ActiveSupport::TestCase
  # Connection states exercised. `:active` and `:stale` both leave the
  # connection status active (stale only differs in sync_state); `:revoked` and
  # `:unavailable` are non-active statuses.
  CONNECTION_STATES = %i[active revoked unavailable stale].freeze
  NON_ACTIVE_STATES = %i[revoked unavailable].freeze

  setup do
    @resolver = PathResolver.new
    @user = users(:visitor1)
    @seq = 0
  end

  # Feature: remote-library-mirror-sync, Property 12: Mirrored-song availability is consistent across selection and resolution
  test "mirrored-song availability agrees between source selection and path resolution, and both are unavailable while the connection is not active" do
    states = CONNECTION_STATES

    check_property(iterations: 100) do
      states[range(0, states.size - 1)]
    end.check do |connection_state|
      song = build_mirrored_song(connection_state)

      # The Mirrored_Song must classify as a remote copy for the property to be
      # meaningful (Req 11.2).
      assert_equal "remote", @resolver.resolve_stream(song, select_source: false)[:stream_source],
        "expected a mirrored song to classify as a remote copy (state=#{connection_state})"

      # Source_Preference selection availability: a single-member group selects
      # the Song when it is available and nothing when it is not (Req 11.2).
      selection_available = !SourcePreference.select([ song ], user: @user).nil?

      # Path_Resolver resolvability for the same Song (Req 11.3).
      resolution_available = @resolver.resolve_stream(song, select_source: false)[:available]

      # (iff) The two consumers of the shared availability rule always agree.
      assert_equal selection_available, resolution_available,
        "selection and resolution availability disagreed for a mirrored song (state=#{connection_state}): " \
        "selection=#{selection_available}, resolution=#{resolution_available}"

      if NON_ACTIVE_STATES.include?(connection_state)
        # (inactive) A non-active connection makes the Mirrored_Song unavailable
        # for both together (Req 11.3).
        assert_equal false, selection_available,
          "expected a mirrored song behind a non-active connection to be unavailable for selection (state=#{connection_state})"
        assert_equal false, resolution_available,
          "expected a mirrored song behind a non-active connection to be unavailable for resolution (state=#{connection_state})"
      else
        # (active) An active connection (fresh or stale sync_state) keeps the
        # Mirrored_Song available for both together (Req 11.2).
        assert_equal true, selection_available,
          "expected a mirrored song behind an active connection to be available for selection (state=#{connection_state})"
        assert_equal true, resolution_available,
          "expected a mirrored song behind an active connection to be available for resolution (state=#{connection_state})"
      end
    end
  end

  private

  def next_seq
    @seq += 1
  end

  # Build a persisted Mirrored_Song in a Remote_Library whose Library_Connection
  # is in the given state. `:stale` keeps the connection status active and only
  # marks its sync_state stale; `:revoked` / `:unavailable` set a non-active
  # status; `:active` is a plain active, fresh connection.
  def build_mirrored_song(connection_state)
    status = NON_ACTIVE_STATES.include?(connection_state) ? connection_state : :active
    sync_state = connection_state == :stale ? "stale" : "fresh"

    n = next_seq
    connection = LibraryConnection.create!(
      user: @user,
      server_base_url: "https://host#{n}.example",
      remote_library_id: n,
      grant_token: "token#{n}",
      status: status,
      sync_state: sync_state
    )
    library = Library.create!(
      name: "Prop12-Mirror-#{SecureRandom.hex(4)}",
      kind: :remote,
      library_connection: connection
    )

    artist = Artist.create!(name: "Prop12-Artist-#{n}", library: library)
    album = Album.create!(name: "Prop12-Album-#{n}", artist: artist, library: library)
    Song.create!(
      name: "Prop12-Mirrored-Song-#{n}",
      file_path: "/remote/prop12-#{n}.mp3",
      file_path_hash: "prop12-fph-#{SecureRandom.hex(8)}",
      md5_hash: "prop12-md5-#{SecureRandom.hex(8)}",
      library: library,
      album: album,
      artist: artist
    )
  end
end
