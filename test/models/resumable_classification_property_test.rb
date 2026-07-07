# frozen_string_literal: true

require "test_helper"

# Property-based test for Property 1 of the audiobook-resume-and-media-ui
# feature.
#
# Design property (audiobook-resume-and-media-ui, Property 1):
#   For any combination of audiobook status and Song duration, a Song is
#   classified as a Resumable_Track if and only if it belongs to an Audiobook
#   OR its duration is at least the Long_Track_Threshold (1200s); a
#   non-audiobook Song shorter than the threshold is never resumable.
#
# This exercises the pure seam Playback::ResumablePolicy.resumable? across a
# boolean audiobook flag and durations spanning 0 well past 1200 including the
# boundary (1200), asserting the classification matches the specification
# `audiobook || duration >= 1200` and that a non-audiobook shorter than the
# threshold is never resumable.
#
# Validates: Requirements 1.1, 1.2, 1.3
class ResumableClassificationPropertyTest < ActiveSupport::TestCase
  THRESHOLD = PlaybackPosition::LONG_TRACK_THRESHOLD # 1200

  # Feature: audiobook-resume-and-media-ui, Property 1: Resumable classification
  test "a song is resumable iff it is an audiobook or its duration is at least the long-track threshold" do
    check_property(iterations: 100) do
      audiobook = boolean
      # Durations spanning 0 well past 1200, including the boundary exactly and
      # values just below/above it, so the threshold edge is always covered.
      duration = freq(
        [ 1, :range, THRESHOLD, THRESHOLD ],  # exact boundary (1200)
        [ 2, :range, 1190, 1210 ],            # tightly around the boundary
        [ 3, :range, 0, 3600 ]                # wide span: 0 well past 1200
      )
      [ audiobook, duration ]
    end.check do |(audiobook, duration)|
      result = Playback::ResumablePolicy.resumable?(audiobook: audiobook, duration: duration)

      expected = audiobook || duration >= THRESHOLD

      assert_equal expected, result,
        "resumable?(audiobook: #{audiobook.inspect}, duration: #{duration.inspect}) " \
        "should equal (audiobook || duration >= #{THRESHOLD})"

      # A non-audiobook shorter than the threshold is never resumable (Req 1.3).
      if !audiobook && duration < THRESHOLD
        assert_not result,
          "a non-audiobook song shorter than #{THRESHOLD}s must never be resumable"
      end
    end
  end
end
