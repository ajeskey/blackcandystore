# frozen_string_literal: true

require "test_helper"

# Property-based test for Property 3 of the audiobook-resume-and-media-ui
# feature.
#
# Design property (audiobook-resume-and-media-ui, Property 3):
#   For any stored Playback_Position, Song duration, and finished flag, the
#   Web_Player's resume target equals the stored position when the record is
#   not finished AND the position is at or above the Minimum_Resume_Position
#   (10s) AND the remaining time exceeds the Finished_Threshold (30s); in every
#   other case (finished, below the minimum, or within the finished threshold)
#   the resume target is 0 (start of Song).
#
# This exercises the pure seam Playback::PositionPolicy.resume_target across
# generated positions spanning [0, duration], both finished flags, and varied
# durations (including short durations so the remaining-time band around the
# Finished_Threshold is covered on both sides).
class ResumeTargetDecisionPropertyTest < ActiveSupport::TestCase
  MINIMUM_RESUME_POSITION = PlaybackPosition::MINIMUM_RESUME_POSITION # 10
  FINISHED_THRESHOLD = PlaybackPosition::FINISHED_THRESHOLD           # 30

  # Feature: audiobook-resume-and-media-ui, Property 3: Resume target decision
  test "resume target equals the stored position only for an unfinished, meaningful, not-yet-finished position" do
    check_property(iterations: 100) do
      # Varied durations, including short ones so remaining time can fall on
      # either side of the Finished_Threshold. `freq` biases toward the small
      # durations that stress the boundary conditions.
      duration = freq(
        [ 3, :range, 0, 120 ],      # short: exercises the finished-threshold band
        [ 2, :range, 121, 3600 ]    # long: typical audiobook chapter lengths
      )

      # A position across the whole [0, duration] range. The integer draw is
      # nudged with a fractional part so non-integer positions are covered too.
      raw = duration.zero? ? 0 : range(0, duration)
      position = [ raw.to_f + (range(0, 99).to_f / 100.0), duration.to_f ].min

      finished = boolean

      [ position, duration.to_f, finished ]
    end.check do |(position, duration, finished)|
      actual = Playback::PositionPolicy.resume_target(
        position: position,
        duration: duration,
        finished: finished
      )

      remaining = duration - position
      should_resume =
        !finished &&
        position >= MINIMUM_RESUME_POSITION &&
        remaining > FINISHED_THRESHOLD

      if should_resume
        assert_equal position, actual,
          "expected resume target to equal the stored position " \
          "(position=#{position}, duration=#{duration}, finished=#{finished})"
      else
        assert_equal 0, actual,
          "expected resume target 0 for a non-resumable case " \
          "(position=#{position}, duration=#{duration}, finished=#{finished}, remaining=#{remaining})"
      end
    end
  end
end
