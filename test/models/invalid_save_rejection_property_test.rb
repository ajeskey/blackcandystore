# frozen_string_literal: true

require "test_helper"

# Property-based test for Property 2 of the audiobook-resume-and-media-ui
# feature.
#
# Design property (audiobook-resume-and-media-ui, Property 2):
#   For any save whose position is negative or greater than the Song's duration,
#   OR whose Song is not a Resumable_Track, the save is rejected with a
#   validation error, no new Playback_Position_Record is created, and any
#   pre-existing record for that (User, Song) pair is left exactly as it was.
#
# This exercises the property at the MODEL layer via the PlaybackPosition
# validations (mirroring the PlaybackPositionsController#update path, which
# builds through Current.user.playback_positions.find_or_initialize_by(song:)).
# It generates three families of invalid save:
#   (a) a negative position on a resumable Song (Req 2.6)
#   (b) a position greater than the Song's duration on a resumable Song (Req 2.6)
#   (c) an in-range position on a NON-resumable Song (Req 2.7, 1.3)
# optionally against a pre-existing valid record for that (User, Song) pair
# (only meaningful for the resumable cases, since a non-resumable Song can never
# hold a valid record).
#
# For each generated save it asserts:
#   * the record is invalid and #save! raises ActiveRecord::RecordInvalid with a
#     validation error on the offending attribute;
#   * the total PlaybackPosition count is unchanged (no new record persisted);
#   * when a pre-existing record was present, reloading it yields byte-for-byte
#     identical position_seconds, finished, and updated_at.
#
# Validates: Requirements 2.6, 2.7, 1.3
class InvalidSaveRejectionPropertyTest < ActiveSupport::TestCase
  INVALID_CASES = %i[negative over_duration non_resumable].freeze

  setup do
    @user = users(:visitor1)

    # A resumable Song: ogg_sample's album (album3) classifies as :music, so
    # lengthening its duration to the Long_Track_Threshold makes it resumable
    # by duration alone.
    @resumable_song = songs(:ogg_sample)
    @resumable_song.update!(duration: PlaybackPosition::LONG_TRACK_THRESHOLD) # 1200

    # A non-resumable Song: mp3_sample (album2, Rock, short) is neither an
    # audiobook nor long enough.
    @non_resumable_song = songs(:mp3_sample)

    assert @resumable_song.resumable?, "expected the fixture song to be resumable"
    assert_not @non_resumable_song.resumable?, "expected the fixture song to be non-resumable"
  end

  # Feature: audiobook-resume-and-media-ui, Property 2: Invalid saves are rejected and leave persistence unchanged
  test "invalid saves are rejected with a validation error and leave any pre-existing record unchanged" do
    check_property(iterations: 100) do
      invalid_case = INVALID_CASES[range(0, INVALID_CASES.length - 1)]
      want_preexisting = boolean
      magnitude = range(0, 100_000)
      orig_pos_raw = range(0, 100_000)
      orig_finished = boolean
      [ invalid_case, want_preexisting, magnitude, orig_pos_raw, orig_finished ]
    end.check do |(invalid_case, want_preexisting, magnitude, orig_pos_raw, orig_finished)|
      # Start each iteration from a clean slate for this user.
      @user.playback_positions.delete_all

      song = invalid_case == :non_resumable ? @non_resumable_song : @resumable_song
      duration = song.duration

      invalid_position =
        case invalid_case
        when :negative
          -(magnitude / 100.0) - 0.1          # always strictly < 0
        when :over_duration
          duration + (magnitude / 100.0) + 0.1 # always strictly > duration
        when :non_resumable
          (magnitude % (duration.to_i + 1)).to_f # in-range [0, duration]: only fault is non-resumability
        end

      # A pre-existing valid record is only possible for a resumable Song.
      has_preexisting = want_preexisting && invalid_case != :non_resumable

      original = nil
      if has_preexisting
        valid_position = PlaybackPosition::MINIMUM_RESUME_POSITION + (orig_pos_raw % 1000) # 10..1009 <= 1200
        record = @user.playback_positions.create!(
          song: song,
          position_seconds: valid_position,
          finished: orig_finished
        )
        record.reload
        original = {
          position_seconds: record.position_seconds,
          finished: record.finished,
          updated_at: record.updated_at
        }
      end

      count_before = PlaybackPosition.count

      # Mirror the controller upsert path: find-or-initialize on the user's
      # relation, apply the (invalid) incoming position, attempt to persist.
      target = @user.playback_positions.find_or_initialize_by(song: song)
      target.position_seconds = invalid_position

      # (Req 2.6, 2.7) The save is rejected with a validation error.
      assert_not target.valid?,
        "expected an invalid save to be rejected (case: #{invalid_case}, position: #{invalid_position})"

      offending_attribute = invalid_case == :non_resumable ? :song : :position_seconds
      assert_includes target.errors.attribute_names, offending_attribute,
        "expected a validation error on #{offending_attribute} for case #{invalid_case}"

      assert_raises(ActiveRecord::RecordInvalid, "expected save! to raise on an invalid save") do
        target.save!
      end

      # (Req 2.6, 2.7, 1.3) No new record was persisted.
      assert_equal count_before, PlaybackPosition.count,
        "expected the PlaybackPosition count to be unchanged after a rejected save"

      # (Req 2.6) Any pre-existing record is left exactly as it was.
      if has_preexisting
        persisted = PlaybackPosition.find_by(user: @user, song: song)
        assert_not_nil persisted, "expected the pre-existing record to still exist"
        persisted.reload
        assert_in_delta original[:position_seconds], persisted.position_seconds, 0.0,
          "expected the pre-existing position_seconds to be unchanged"
        assert_equal original[:finished], persisted.finished,
          "expected the pre-existing finished flag to be unchanged"
        assert_equal original[:updated_at], persisted.updated_at,
          "expected the pre-existing updated_at to be unchanged"
      end
    end
  end
end
