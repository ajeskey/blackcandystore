# frozen_string_literal: true

module Playback
  # ResumablePolicy is a pure predicate (no I/O) over the two facts that make a
  # Song eligible for playback-position resume (a Resumable_Track):
  #
  #   - it belongs to an Audiobook Album (ContentClassifier => :audiobook), or
  #   - its duration is at least the Long_Track_Threshold.
  #
  # A non-audiobook Song shorter than the threshold is never resumable, so it
  # never gets a PlaybackPosition record (Req 1.1, 1.2, 1.3).
  #
  # The model adapts to this seam via Song#resumable?:
  #   ResumablePolicy.resumable?(audiobook: album&.audiobook?, duration: duration)
  module ResumablePolicy
    module_function

    # Returns true when the Song qualifies as a Resumable_Track.
    def resumable?(audiobook:, duration:)
      audiobook || duration.to_f >= PlaybackPosition::LONG_TRACK_THRESHOLD
    end
  end
end
