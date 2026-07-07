# frozen_string_literal: true

require "test_helper"

# Property-based test for Property 5 of the audiobook-resume-and-media-ui
# feature.
#
# Design property (audiobook-resume-and-media-ui, Property 5):
#   For any set of Playback_Position_Records and any set of authorized library
#   ids, the Continue_Listening_List contains exactly those records whose
#   position is at or above the Minimum_Resume_Position (10s), that are not
#   finished, and whose Song belongs to an authorized library; the result is
#   ordered by last-updated time most-recent-first and contains at most 20
#   items (the 20 most recently updated when more qualify).
#
# This exercises the pure seam Playback::ContinueListeningPolicy.select across
# generated lists of record doubles with random position_seconds / finished /
# library_id / updated_at, random authorized-library-id sets, and lists longer
# than the MAX_ITEMS cap so both the ordering and the cap are stressed.
class ContinueListeningSelectionPropertyTest < ActiveSupport::TestCase
  MINIMUM_RESUME_POSITION = PlaybackPosition::MINIMUM_RESUME_POSITION # 10
  MAX_ITEMS = Playback::ContinueListeningPolicy::MAX_ITEMS            # 20

  # A simple stand-in for a Playback_Position_Record. It responds to exactly the
  # four messages the pure seam reads: position_seconds, finished, updated_at,
  # library_id.
  Record = Struct.new(:position_seconds, :finished, :updated_at, :library_id)

  # Feature: audiobook-resume-and-media-ui, Property 5: Continue-listening filtering, ordering, and cap
  test "continue-listening keeps exactly the qualifying records, ordered most-recent-first, capped at 20" do
    check_property(iterations: 100) do
      # The universe of library ids records may belong to. Kept small so the
      # authorized subset both includes and excludes records frequently.
      library_ids = (1..range(1, 6)).to_a

      # A random subset of those ids the User is authorized to access. May be
      # empty (User with no authorized libraries) or the full set.
      authorized = library_ids.select { boolean }

      # Generate lists that frequently exceed MAX_ITEMS so the cap is exercised,
      # while still covering small lists (including empty). updated_at values are
      # epoch seconds; ties are possible so tie handling is covered.
      count = freq(
        [ 2, :range, 0, MAX_ITEMS ],           # small / at-or-below the cap
        [ 3, :range, MAX_ITEMS + 1, 60 ]       # larger than the cap
      )

      records = Array.new(count) do
        # Positions straddle the Minimum_Resume_Position on both sides.
        position = range(0, 40).to_f + (range(0, 99).to_f / 100.0)
        finished = boolean
        updated_at = range(1_600_000_000, 1_600_000_100) # narrow window => ties
        library_id = library_ids[range(0, library_ids.length - 1)]
        Record.new(position, finished, updated_at, library_id)
      end

      [ records, authorized ]
    end.check do |(records, authorized)|
      result = Playback::ContinueListeningPolicy.select(records, authorized_library_ids: authorized)

      allowed = authorized.to_set
      qualifying = records.select do |r|
        r.position_seconds >= MINIMUM_RESUME_POSITION &&
          !r.finished &&
          allowed.include?(r.library_id)
      end

      # (Req 4.6) The result never exceeds the cap.
      assert result.length <= MAX_ITEMS,
        "expected at most #{MAX_ITEMS} items, got #{result.length}"

      # (Req 4.6) The length is exactly the number of qualifying records, or the
      # cap when more qualify.
      assert_equal [ qualifying.length, MAX_ITEMS ].min, result.length,
        "expected #{[ qualifying.length, MAX_ITEMS ].min} items, got #{result.length}"

      # (Req 4.1, 4.3, 4.4) Every returned record is a qualifying record and no
      # disqualified record slips through.
      result.each do |r|
        assert r.position_seconds >= MINIMUM_RESUME_POSITION,
          "returned a record below the minimum resume position (#{r.position_seconds})"
        assert_not r.finished, "returned a finished record"
        assert allowed.include?(r.library_id),
          "returned a record from an unauthorized library (#{r.library_id})"
      end

      # (Req 4.2) The result is ordered by updated_at, most-recent-first.
      updated_ats = result.map(&:updated_at)
      assert_equal updated_ats.sort.reverse, updated_ats,
        "expected the result ordered by updated_at descending"

      # (Req 4.2, 4.6) When capped, the retained items are the most-recently
      # updated qualifying records: no dropped qualifying record is newer than a
      # retained one.
      if qualifying.length > MAX_ITEMS
        retained = result.to_set
        dropped = qualifying.reject { |r| retained.include?(r) }
        min_retained_updated_at = result.map(&:updated_at).min
        dropped.each do |r|
          assert r.updated_at <= min_retained_updated_at,
            "a dropped qualifying record (#{r.updated_at}) is newer than a retained one (#{min_retained_updated_at})"
        end
      end
    end
  end
end
