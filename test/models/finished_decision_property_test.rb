# frozen_string_literal: true

require "test_helper"

# Property-based test for Property 4 of the audiobook-resume-and-media-ui
# feature.
#
# Design property (audiobook-resume-and-media-ui, Property 4):
#   For any saved Playback_Position, Song duration, and client finished-signal,
#   the record's finished flag after the save is true if and only if the client
#   signalled finished OR the remaining time (duration minus position) is at or
#   below the Finished_Threshold (30s). Because the flag is recomputed from that
#   save's inputs alone, a save near the start of a previously finished Song (no
#   client signal, remaining above the threshold) yields finished = false.
#
# This exercises the pure seam
# `Playback::PositionPolicy.finished_after_save(position:, duration:, client_finished:)`
# which returns `client_finished || finished?(position:, duration:)`, where
# `finished?` is `(duration - position) <= FINISHED_THRESHOLD` (30s).
#
# Generators cover positions near/below/above the finished band together with
# client_finished true/false, and the property additionally pins down the
# near-start restart case (Req 5.4) where no client signal and ample remaining
# time must yield finished = false.
class FinishedDecisionPropertyTest < ActiveSupport::TestCase
  THRESHOLD = PlaybackPosition::FINISHED_THRESHOLD # 30 seconds remaining

  # Where the generated position sits relative to the finished band
  # (remaining <= THRESHOLD).
  POSITION_BANDS = %i[below near above start].freeze

  # Feature: audiobook-resume-and-media-ui, Property 4: Finished decision
  test "finished flag after a save is exactly (client_finished OR remaining <= threshold), recomputed per save" do
    check_property(iterations: 100) do
      duration = range(THRESHOLD + 1, 50_000)
      band = POSITION_BANDS[range(0, POSITION_BANDS.length - 1)]
      client_finished = boolean

      position =
        case band
        when :below
          # remaining strictly greater than the threshold => not finished by time
          remaining = range(THRESHOLD + 1, duration)
          duration - remaining
        when :near
          # straddle the boundary: remaining within a few seconds of THRESHOLD
          remaining = range(THRESHOLD - 2, THRESHOLD + 2)
          [ duration - remaining, 0 ].max
        when :above
          # remaining at or below the threshold => finished by time
          remaining = range(0, THRESHOLD)
          duration - remaining
        when :start
          # near the very start of the song, always ample remaining time
          range(0, PlaybackPosition::MINIMUM_RESUME_POSITION - 1)
        end

      [ position, duration, band, client_finished ]
    end.check do |(position, duration, band, client_finished)|
      finished = Playback::PositionPolicy.finished_after_save(
        position: position,
        duration: duration,
        client_finished: client_finished
      )

      expected = client_finished || ((duration - position) <= THRESHOLD)

      assert_equal expected, finished,
        "finished_after_save(position: #{position}, duration: #{duration}, " \
        "client_finished: #{client_finished}) should be #{expected} " \
        "(remaining=#{duration - position}, threshold=#{THRESHOLD}, band=#{band})"

      # Req 5.4: a save near the start with no client signal clears/keeps the
      # finished flag false regardless of any prior finished state.
      if band == :start && !client_finished
        assert_not finished,
          "a near-start save (position=#{position}) with client_finished=false " \
          "must yield finished=false (remaining=#{duration - position})"
      end
    end
  end
end
