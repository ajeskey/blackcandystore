# frozen_string_literal: true

require "test_helper"

# Property-based test for the loop-at-end behaviour of the ProgramSequencer
# Shared_Playlist seam (design Property 7).
#
# A Shared_Playlist (Party_Session / Co_Listen_Session) is an *ordered* list of
# entries the sequencer advances through in `MODE_PLAYLIST`. Property 7 states:
# once the last entry has played, the next selection is the first entry, so
# playback wraps to the beginning WITHOUT an interruption or exhaustion result
# (Req 6.7, 7.8).
#
# The sequencer is a pure, deterministic function seam: callers keep the
# "recently played" history and it decides the next item with no I/O. So the
# whole property is exercised directly, no Broadcaster and no database required.
# Each iteration drives the sequencer through its own generated playlist,
# feeding back each selection as the newest history entry (exactly as a live
# broadcast would), and asserts:
#   * the very first selection (empty history) is the first entry,
#   * every selection is a real playlist entry (never ineligible, never
#     continuity — the playlist is non-empty),
#   * the selection sequence is the playlist repeated in order, and
#   * the step immediately after the last entry is the first entry (the wrap).
#
# Playlists are generated with DISTINCT song ids so "the last entry has played"
# is unambiguous: with distinct ids the most-recently-played entry pins the
# position exactly, which is the precise situation Property 7 constrains.
class ProgramSequencerLoopPropertyTest < ActiveSupport::TestCase
  # Feature: radio-party-colisten, Property 7: Shared_Playlist loops at its end
  test "playing a Shared_Playlist to its end selects the first entry next, wrapping to the beginning without interruption or exhaustion" do
    check_property(iterations: 100) do
      # An ordered playlist of distinct song ids (size 1..8) and a number of
      # full loops (2..4) to walk so the wrap at the end is exercised more than
      # once per iteration.
      size = range(1, 8)
      ids = Array.new(size) { range(1, 10_000) }.uniq
      loops = range(2, 4)

      [ ids, loops ]
    end.check do |(playlist, loops)|
      # `uniq` may shrink the list; a Shared_Playlist always has at least one
      # entry in this property, so guard the (rare) all-duplicates shrink.
      next if playlist.empty?

      history = []
      total_steps = playlist.length * loops

      total_steps.times do |step|
        selection = ProgramSequencer.next_selection(
          playlist,
          history: history,
          mode: ProgramSequencer::MODE_PLAYLIST
        )

        # A non-empty playlist must never yield continuity or exhaustion: the
        # stream stays open by looping (Req 6.7, 7.8).
        assert selection.song?,
          "a non-empty Shared_Playlist must always select a song, never continuity (step #{step})"
        assert_includes playlist, selection.song_id,
          "every selection must be an entry of the playlist (step #{step})"

        # The sequence of selections is the playlist repeated in order, so the
        # step after the last entry wraps back to the first entry.
        expected = playlist[step % playlist.length]
        assert_equal expected, selection.song_id,
          "selection #{step} must follow playlist order and wrap at the end"

        # Explicitly assert the wrap at each end-of-playlist boundary: the entry
        # chosen right after the last entry has played is the first entry.
        if step.positive? && (step % playlist.length).zero?
          assert_equal playlist.first, selection.song_id,
            "after the last entry has played the sequencer must select the first entry (wrap)"
        end

        history << selection.song_id
      end
    end
  end

  # Feature: radio-party-colisten, Property 7: Shared_Playlist loops at its end
  test "directly after the last entry has just played the next selection is the first entry regardless of prior history" do
    check_property(iterations: 100) do
      # A distinct-id playlist plus an arbitrary run of already-played entries
      # drawn from it; we then force the last playlist entry to be the most
      # recent play so "the last entry has played" holds for any prior history.
      size = range(1, 8)
      playlist = Array.new(size) { range(1, 10_000) }.uniq
      prior_len = range(0, 10)
      prior = Array.new(prior_len) { |_| playlist.empty? ? 0 : choose(*playlist) }

      [ playlist, prior ]
    end.check do |(playlist, prior)|
      next if playlist.empty?

      # History ends with the last playlist entry => the last entry has just
      # played, whatever came before it.
      history = prior + [ playlist.last ]

      selection = ProgramSequencer.next_selection(
        playlist,
        history: history,
        mode: ProgramSequencer::MODE_PLAYLIST
      )

      assert selection.song?,
        "looping at the end must produce a song selection, not continuity or exhaustion"
      assert_equal playlist.first, selection.song_id,
        "once the last entry has played the sequencer must wrap to the first entry"
    end
  end
end
