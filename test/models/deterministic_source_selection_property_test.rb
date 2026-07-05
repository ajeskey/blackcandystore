# frozen_string_literal: true

require "test_helper"

# Property-based test for Property 18 of the multi-server-library-sharing
# feature.
#
# Design property (multi-server-library-sharing, Property 18):
#   For any Duplicate_Group with at least one available copy and any User
#   Source_Preference, the Server SHALL select exactly one playable Song
#   according to the deterministic ordering -- under `prefer_own_server`: the
#   copy in the User's own Local_Library, else the highest-quality copy; under
#   `prefer_highest_quality`: the highest-quality copy ranked by lossless
#   status, then bit depth, then bitrate -- with ties broken by preferring the
#   User's own Local_Library and otherwise the lowest Library identifier; and
#   when no copy is available it SHALL select none and mark the content
#   unavailable.
#
# The test generates a Duplicate_Group as a random set of candidate Songs drawn
# from a pool of libraries with varying availability (the User's own local
# library, other local libraries, remote libraries reached through an active
# Library_Connection, and remote libraries whose connection is revoked) and a
# varying bit depth per copy, together with a randomly chosen Source_Preference.
# Zero-available groups (empty groups and groups whose every copy lives behind a
# revoked remote connection) are generated as well.
#
# Each Song is placed in a distinct library, matching the Duplicate_Group domain
# (one copy per source) so the documented ordering -- which bottoms out at the
# Library identifier -- is a strict total order.
#
# For every generated group + preference the test:
#   (a) computes the expected selection INDEPENDENTLY from the documented rules
#       (own-first-or-quality; quality = lossless -> bit depth -> bitrate;
#       tiebreak own -> lowest library id) among the AVAILABLE copies, and
#       asserts SourcePreference.select returns exactly that one Song
#       (Req 11.4, 11.5, 11.6, 11.7, 11.8, 12.7);
#   (b) asserts nil is returned when no copy is available (Req 11.9, 12.11);
#   (c) asserts determinism -- selecting again over a shuffled input returns the
#       same Song / nil (Req 12.6).
class DeterministicSourceSelectionPropertyTest < ActiveSupport::TestCase
  PREFERENCES = %w[prefer_own_server prefer_highest_quality].freeze
  # nil bit depth models a lossy copy; a present bit depth models a lossless
  # copy at that depth (Song#lossless? is defined as bit_depth.present?).
  BIT_DEPTHS = [ nil, 8, 16, 24 ].freeze

  setup do
    @user = users(:visitor1)
    @album = albums(:album1)
    @artist = artists(:artist1)
    @counter = 0

    # A pool of libraries covering every availability category. Each library has
    # a distinct id so the "lowest library id" tiebreak is a strict order. The
    # User's own local library is the Default_Library (owned by visitor1).
    @own_library = libraries(:default_library)
    @other_locals = [ create_local_library, create_local_library ]
    @remote_actives = [ create_remote_library(:active), create_remote_library(:active) ]
    @remote_revoked = [ create_remote_library(:revoked), create_remote_library(:revoked) ]

    @pool = [ @own_library, *@other_locals, *@remote_actives, *@remote_revoked ]
    # Indices into @pool whose copies are unavailable (revoked remote).
    revoked_ids = @remote_revoked.map(&:id)
    @unavailable_indices = @pool.each_index.select { |i| revoked_ids.include?(@pool[i].id) }
  end

  # Feature: multi-server-library-sharing, Property 18: Source preference selects exactly one copy deterministically
  test "source preference selects exactly one available copy deterministically, and none when unavailable" do
    # The generator block is evaluated in the Rantly instance's context, so
    # capture the pool shape as locals it can close over.
    all_indices = (0...@pool.length).to_a
    unavailable_indices = @unavailable_indices

    check_property(iterations: 100) do
      scenario = choose(:mixed, :mixed, :mixed, :empty, :only_unavailable)
      preference = choose(*PREFERENCES)

      selections =
        case scenario
        when :empty
          []
        when :only_unavailable
          picks = unavailable_indices.select { boolean }
          picks = [ unavailable_indices.sample ] if picks.empty?
          picks.map { |i| [ i, BIT_DEPTHS.sample ] }
        else
          all_indices.select { boolean }.map { |i| [ i, BIT_DEPTHS.sample ] }
        end

      [ selections, preference ]
    end.check do |(selections, preference)|
      @user.source_preference = preference

      group = selections.map { |(index, bit_depth)| build_song(library: @pool[index], bit_depth: bit_depth) }

      expected = expected_selection(group, preference)
      actual = SourcePreference.select(group, user: @user)

      if expected.nil?
        # (b) No available copy -> no Song selected, content unavailable
        # (Req 11.9, 12.11).
        assert_nil actual,
          "expected no selection when every candidate copy is unavailable"
      else
        # (a) Exactly the one copy the documented ordering picks (Req 11.4-11.8, 12.7).
        assert_equal expected, actual,
          "expected the deterministic selection under #{preference}"
      end

      # (c) Determinism: the same inputs (in any order) always yield the same
      # result (Req 12.6).
      5.times do
        reselected = SourcePreference.select(group.shuffle, user: @user)
        if expected.nil?
          assert_nil reselected, "expected a deterministic nil under #{preference}"
        else
          assert_equal expected, reselected,
            "expected a deterministic selection independent of input order under #{preference}"
        end
      end
    end
  end

  private

  # --- independent expected-selection logic ----------------------------------
  # Mirrors the documented ordering rules without reusing the implementation, so
  # a divergence between the rules and the code surfaces as a counterexample.

  def expected_selection(songs, preference)
    available = songs.select { |song| available?(song) }
    return nil if available.empty?

    available.min_by { |song| ranking_key(song, preference) }
  end

  # local copies are always available; a remote copy is available only through
  # an active Library_Connection (Req 11.6, 12.7).
  def available?(song)
    library = song.library
    return false if library.nil?

    if library.remote?
      connection = library.library_connection
      connection.present? && connection.active?
    else
      true
    end
  end

  def ranking_key(song, preference)
    if preference == "prefer_highest_quality"
      [ *quality_key(song), own_rank(song), song.library_id ]
    else
      # prefer_own_server: the own copy dominates quality (Req 11.4, 11.7).
      [ own_rank(song), *quality_key(song), own_rank(song), song.library_id ]
    end
  end

  # Best first: lossless before lossy, then higher bit depth, then higher
  # bitrate (there is no stored bitrate, so it is unknown/0) (Req 11.5).
  def quality_key(song)
    [ song.lossless? ? 0 : 1, -song.bit_depth.to_i, -0 ]
  end

  # 0 when the copy is in the User's own Local_Library, else 1 (Req 11.4, 11.8).
  def own_rank(song)
    own_library?(song) ? 0 : 1
  end

  def own_library?(song)
    library = song.library
    library.present? && library.local? && library.owner_id == @user.id
  end

  # --- fixtures / factories --------------------------------------------------

  def create_local_library
    @lib_counter = (@lib_counter || 0) + 1
    Library.create!(
      name: "Prop18 Local #{SecureRandom.hex(4)}",
      kind: :local,
      media_path: Rails.root.join("test", "fixtures", "files").to_s
    )
  end

  def create_remote_library(status)
    @remote_counter = (@remote_counter || 0) + 1
    connection = LibraryConnection.create!(
      user: @user,
      server_base_url: "https://host#{@remote_counter}.example",
      remote_library_id: @remote_counter,
      grant_token: "token#{@remote_counter}",
      status: status
    )
    Library.create!(name: "Prop18 Remote #{SecureRandom.hex(4)}", kind: :remote, library_connection: connection)
  end

  # Each Song gets a distinct md5 per library (and a unique file path hash) so
  # copies remain distinguishable rows.
  def build_song(library:, bit_depth:)
    @counter += 1
    Song.create!(
      name: "prop18_track_#{@counter}",
      file_path: "/tmp/prop18_track_#{@counter}.flac",
      file_path_hash: "prop18_fph_#{@counter}_#{SecureRandom.hex(4)}",
      md5_hash: "prop18_md5_#{library.id}_#{@counter}",
      album: @album,
      artist: @artist,
      library: library,
      bit_depth: bit_depth
    )
  end
end
