# frozen_string_literal: true

require "test_helper"

# Property-based test for the Program_Sequencer eligibility/never-exhausts seam
# of the radio-party-colisten feature (design Property 5).
#
# ProgramSequencer is a pure, deterministic function seam, so this exercises it
# directly with generated song-id sets/playlists and arbitrary play histories —
# no database, no Broadcaster, no clock. Song ids are plain integers here; the
# sequencer accepts either bare ids or Song-like records.
#
# Property 5 (design): for ANY non-empty eligible-song set (MODE_STATION) or
# non-empty Shared_Playlist (MODE_PLAYLIST) and ANY play history, the next
# selection is always a member of the source set, and it NEVER returns an
# exhaustion/continuity result while the source is non-empty — it keeps
# selecting further eligible items even after every item has already been
# played.
class ProgramSequencerEligibilityPropertyTest < ActiveSupport::TestCase
  # Feature: radio-party-colisten, Property 5: Program_Sequencer always selects an eligible item and never exhausts
  test "for any non-empty eligible set or playlist and any history, the next selection is always a member of the source and never exhausts" do
    check_property(iterations: 100) do
      # The source: a non-empty pool of song ids. Consecutive ids 1..n keep the
      # set non-empty; playlists may repeat entries (a Shared_Playlist can hold
      # the same Song more than once under the `allow` duplicate policy), so we
      # optionally duplicate entries for the playlist case.
      source_size = range(1, 8)
      source_ids = (1..source_size).to_a
      mode = choose(ProgramSequencer::MODE_STATION, ProgramSequencer::MODE_PLAYLIST)

      # For playlists, optionally append duplicates so looping is exercised over
      # a list that is not a plain set.
      duplicates = Array.new(range(0, 3)) { choose(*source_ids) }
      source = (mode == ProgramSequencer::MODE_PLAYLIST) ? source_ids + duplicates : source_ids

      # An arbitrary play history, oldest first. Entries are drawn mostly from
      # the source but occasionally a "foreign" id (no longer / never in the
      # source) so the sequencer's tolerance of stale history is covered.
      history_len = range(0, 20)
      history = Array.new(history_len) do
        # ~1 in 5 entries is a foreign id outside the source; the rest are drawn
        # from the source.
        (range(0, 4) == 0) ? 1000 + range(0, 50) : choose(*source_ids)
      end

      # Deliberately drive the "every eligible item has already been played"
      # branch (Req 2.3): when set, guarantee the history already contains every
      # source id so the sequencer must re-select from the full set rather than
      # exhaust.
      played_all = boolean
      history = source_ids + history if played_all

      [ mode, source, history ]
    end.check do |(mode, source, history)|
      selection = ProgramSequencer.next_selection(source, history: history, mode: mode)

      assert selection.song?,
        "a non-empty #{mode} source must yield a song selection, never continuity " \
        "(source=#{source.inspect} history=#{history.inspect})"
      assert_not selection.continuity?,
        "the sequencer must never report exhaustion/continuity while the source is non-empty " \
        "(source=#{source.inspect} history=#{history.inspect})"
      assert_includes source, selection.song_id,
        "the selected song must be a member of the eligible set/playlist " \
        "(selected=#{selection.song_id.inspect} source=#{source.inspect})"
    end
  end
end
