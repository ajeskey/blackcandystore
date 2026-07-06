# frozen_string_literal: true

require "test_helper"

# Property-based test for the ProgramSequencer continuity seam of the
# radio-party-colisten feature (design Property 6).
#
# ProgramSequencer is a pure, deterministic function seam (like
# PlaybackController), so this property is exercised directly against the model
# with plain integer song ids — no database, no Broadcaster, no controller.
#
# Property 6 concerns the moment at which *nothing is resolvable*:
#   * a Radio_Station whose eligible-song set is empty (MODE_STATION), or
#   * a Co_Listen_Session whose Shared_Playlist is empty (MODE_PLAYLIST) — no
#     Song has ever been added.
# In either case the sequencer must yield a `:continuity` directive rather than
# an exhaustion/close result, keeping the Shared_Stream open. The stream stays
# open only *until* an eligible/added Song becomes available: once the source is
# non-empty the sequencer resolves an actual song instead of continuity.
class ProgramSequencerContinuityPropertyTest < ActiveSupport::TestCase
  MODES = [ ProgramSequencer::MODE_STATION, ProgramSequencer::MODE_PLAYLIST ].freeze

  # Feature: radio-party-colisten, Property 6: Continuity when nothing is resolvable
  test "when the eligible set or Shared_Playlist is empty the sequencer yields a continuity directive for any history, and resolves a real song once one becomes available" do
    check_property(iterations: 100) do
      # A selection mode (station eligible-set vs co-listen playlist), an
      # arbitrary "recently played" history (possibly empty, possibly holding
      # ids that are no longer — or never were — in the source), and a candidate
      # song id that later "becomes available" so the reopen case is covered.
      mode = choose(*MODES)
      history = Array.new(range(0, 8)) { range(1, 1000) }
      candidate = range(1, 1000)

      [ mode, history, candidate ]
    end.check do |(mode, history, candidate)|
      # --- nothing resolvable: empty source ---
      empty = ProgramSequencer.next_selection([], history: history, mode: mode)

      assert empty.continuity?,
        "an empty #{mode} source must yield a :continuity directive (history=#{history.inspect})"
      assert_not empty.song?,
        "a continuity directive must not carry a song selection"
      assert_nil empty.song_id,
        "a continuity directive carries no song_id"
      assert_equal ProgramSequencer::TYPE_CONTINUITY, empty.type,
        "the sequencer must signal continuity, never an exhaustion/close result"

      # --- the stream reopens once a Song becomes available ---
      resolved = ProgramSequencer.next_selection([ candidate ], history: history, mode: mode)

      assert resolved.song?,
        "once an eligible/added Song exists the sequencer resolves a song, not continuity"
      assert_not resolved.continuity?,
        "a non-empty source must not yield continuity"
      assert_equal candidate, resolved.song_id,
        "the resolved selection must be the newly available song"
    end
  end
end
