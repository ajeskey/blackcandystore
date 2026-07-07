# frozen_string_literal: true

class PlaybackPosition < ApplicationRecord
  LONG_TRACK_THRESHOLD    = 1200   # seconds (Req 1.2, A2)
  MINIMUM_RESUME_POSITION = 10     # seconds (Req 3.1, 3.3)
  FINISHED_THRESHOLD      = 30     # seconds remaining (Req 5.1)
  SAVE_INTERVAL           = 10     # seconds (Req 2.1, 2.2)

  belongs_to :user
  belongs_to :song

  validates :song_id, uniqueness: { scope: :user_id }
  validate  :song_must_be_resumable          # Req 2.7
  validate  :position_within_duration        # Req 2.6

  delegate :library_id, to: :song

  private

  def song_must_be_resumable
    errors.add(:song, :not_resumable) unless song&.resumable?
  end

  def position_within_duration
    return if song.nil?

    unless Playback::PositionPolicy.valid_position?(position_seconds, song.duration)
      errors.add(:position_seconds, :out_of_range)
    end
  end
end
