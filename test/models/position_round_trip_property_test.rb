# frozen_string_literal: true

require "test_helper"

# Property-based test for Property 6 of the audiobook-resume-and-media-ui
# feature.
#
# Design property (audiobook-resume-and-media-ui, Property 6):
#   For any sequence of one or more valid position saves for a (User, Song)
#   pair, reading the stored Playback_Position_Record returns the most recently
#   saved position, and the record's last-updated timestamp never moves backward
#   across successive saves.
#
# This exercises PlaybackPositionsController#update / #show at the MODEL layer,
# mirroring the controller's upsert path: find_or_initialize_by(song:) on
# user.playback_positions, set position_seconds, recompute finished via
# Playback::PositionPolicy.finished_after_save, and save!. Over generated
# sequences of valid positions for a single (user, song) pair it asserts:
#   (last-write-wins, Req 2.4, 2.5, 6.2) the stored position_seconds equals the
#     most recently saved position; and
#   (monotonic updated_at, Req 2.5) updated_at never moves backward across
#     successive saves.
#
# It runs in the transactional test DB so 100+ iterations stay cheap.
class PositionRoundTripPropertyTest < ActiveSupport::TestCase
  setup do
    @user = users(:visitor1)
    @song = songs(:mp3_sample)
    # Lengthen the song so it qualifies as a Resumable_Track regardless of
    # content type (duration >= LONG_TRACK_THRESHOLD) and so valid positions
    # span a wide range. update_column avoids re-running file-backed validations.
    @song.update_column(:duration, 3600.0)
    @duration = @song.duration
  end

  # Feature: audiobook-resume-and-media-ui, Property 6: Position write/read round-trip (last write wins)
  test "reading a (user, song) position returns the most recent valid save and updated_at never moves backward" do
    check_property(iterations: 100) do
      # A sequence of one or more valid positions within [0, duration].
      length = range(1, 12)
      positions = Array.new(length) { range(0, @duration.to_i) }
      positions
    end.check do |positions|
      # Isolate each iteration: start from no record for this (user, song) pair.
      @user.playback_positions.where(song: @song).delete_all

      previous_updated_at = nil

      positions.each do |position|
        # Mirror PlaybackPositionsController#update's upsert path.
        record = @user.playback_positions.find_or_initialize_by(song: @song)
        record.position_seconds = position
        record.finished = Playback::PositionPolicy.finished_after_save(
          position: position,
          duration: @duration,
          client_finished: false
        )
        record.save!
        record.reload

        # Req 2.5: updated_at never moves backward across successive saves.
        if previous_updated_at
          assert record.updated_at >= previous_updated_at,
            "updated_at moved backward: #{record.updated_at.inspect} < #{previous_updated_at.inspect}"
        end
        previous_updated_at = record.updated_at
      end

      # Req 2.4, 2.5, 6.2: reading the record returns the most recently saved position.
      stored = @user.playback_positions.find_by(song: @song)
      assert_not_nil stored, "expected a persisted Playback_Position_Record after saves"
      assert_in_delta positions.last, stored.position_seconds, 1e-6,
        "stored position should equal the most recently saved position (last write wins)"
    end
  end
end
