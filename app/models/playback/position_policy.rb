# frozen_string_literal: true

# Pure decision seam for playback-position rules (no I/O). Isolates the
# correctness-sensitive math shared by the position API and mirrored in the
# Web_Player: validating a saved position, deciding when a track is finished,
# and computing where to resume.
#
# References the fixed constants defined on the PlaybackPosition model
# (MINIMUM_RESUME_POSITION, FINISHED_THRESHOLD) so Ruby and JS never drift.
module Playback::PositionPolicy
  module_function

  # Req 2.6: a position must be within [0, duration].
  def valid_position?(position, duration)
    position.is_a?(Numeric) && position >= 0 && position <= duration.to_f
  end

  # Req 5.1/5.5: server backup — finished when remaining <= FINISHED_THRESHOLD.
  def finished?(position:, duration:)
    (duration.to_f - position) <= PlaybackPosition::FINISHED_THRESHOLD
  end

  # Req 5.2/5.4/5.5: the finished flag stored on a save is the client's explicit
  # signal OR the server's remaining-time backup. Recomputed on every save, so a
  # restart near the beginning clears a stale finished flag (Req 5.4).
  def finished_after_save(position:, duration:, client_finished:)
    client_finished || finished?(position: position, duration: duration)
  end

  # Req 3.1–3.4: seconds the Web_Player should seek to when opening a track.
  # Returns 0 (start) unless there is a meaningful, unfinished resume point.
  def resume_target(position:, duration:, finished:)
    return 0 if finished
    return 0 if position < PlaybackPosition::MINIMUM_RESUME_POSITION
    return 0 if finished?(position: position, duration: duration)

    position
  end
end
