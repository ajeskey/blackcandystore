# frozen_string_literal: true

require "test_helper"

# Example/unit tests for the PlaybackPosition model, its associations, and the
# Song#resumable? predicate (Phase 1 of the audiobook-resume-and-media-ui
# feature).
#
# These complement the pure-seam property tests: here we exercise the model's
# validations, the (user_id, song_id) uniqueness, the dependent: :destroy
# association cascade, and that Song#resumable? derives audiobook status from
# the existing ContentClassifier via Album#audiobook? rather than a separate
# flag.
#
# Covers: Requirements 1.4, 7.5 (with 2.6, 2.7 exercised through the model
# validations that back a valid save).
class PlaybackPositionTest < ActiveSupport::TestCase
  setup do
    @user = users(:visitor1)
  end

  # --- Song#resumable? (Req 1.1, 1.4) ---

  test "Song#resumable? derives audiobook status from ContentClassifier via Album#audiobook?" do
    # mp3_sample belongs to album2 (genre Rock, short duration) so it starts out
    # non-resumable — neither an audiobook nor long enough.
    song = songs(:mp3_sample)
    assert_not song.album.audiobook?
    assert_not song.resumable?

    # Tagging the album with an audiobook genre flips ContentClassifier to
    # :audiobook, which is the ONLY thing that changes here — the song is still
    # short. resumable? must follow the classifier, not a stored flag (Req 1.4).
    song.album.update!(genre: "Audiobook")
    song.reload

    assert song.album.audiobook?
    assert song.resumable?,
      "a short song must become resumable once its album classifies as an audiobook"
  end

  test "Song#resumable? is true for a long non-audiobook song at the threshold, false just below" do
    # ogg_sample belongs to album3 (no audiobook/live tags) => classified :music.
    song = songs(:ogg_sample)
    assert_not song.album.audiobook?

    song.update!(duration: PlaybackPosition::LONG_TRACK_THRESHOLD - 1) # 1199
    assert_not song.resumable?,
      "a non-audiobook song shorter than the long-track threshold must not be resumable"

    song.update!(duration: PlaybackPosition::LONG_TRACK_THRESHOLD) # 1200
    assert song.resumable?,
      "a non-audiobook song at the long-track threshold must be resumable"
  end

  test "Song#resumable? is false for a short non-audiobook song" do
    song = songs(:mp3_sample) # album2, Rock, 8.0s
    assert_not song.album.audiobook?
    assert_operator song.duration, :<, PlaybackPosition::LONG_TRACK_THRESHOLD
    assert_not song.resumable?
  end

  # --- Associations / cascade (Req 7.5) ---

  test "deleting a user destroys that user's playback positions" do
    user = User.create!(email: "resume@blackcandy.com", password: "foobar")
    position = user.playback_positions.create!(song: resumable_song, position_seconds: 100.0)

    assert PlaybackPosition.exists?(position.id)

    user.destroy

    assert_not PlaybackPosition.exists?(position.id),
      "a user's playback positions must be removed when the user is deleted"
  end

  # --- Uniqueness of (user_id, song_id) ---

  test "playback position is unique per (user_id, song_id)" do
    song = resumable_song
    @user.playback_positions.create!(song: song, position_seconds: 50.0)

    duplicate = @user.playback_positions.build(song: song, position_seconds: 60.0)

    assert_not duplicate.valid?
    assert_includes duplicate.errors.attribute_names, :song_id
  end

  test "the same song may have a playback position for different users" do
    song = resumable_song
    @user.playback_positions.create!(song: song, position_seconds: 50.0)

    other_user = User.create!(email: "other-resume@blackcandy.com", password: "foobar")
    other_position = other_user.playback_positions.build(song: song, position_seconds: 60.0)

    assert other_position.valid?, other_position.errors.full_messages.inspect
  end

  # --- Validations: resumable song (Req 2.7) ---

  test "rejects a playback position for a non-resumable song" do
    non_resumable = songs(:mp3_sample) # short, non-audiobook
    assert_not non_resumable.resumable?

    position = @user.playback_positions.build(song: non_resumable, position_seconds: 1.0)

    assert_not position.valid?
    assert_includes position.errors.attribute_names, :song
  end

  # --- Validations: position within [0, duration] (Req 2.6) ---

  test "rejects a negative position" do
    position = @user.playback_positions.build(song: resumable_song, position_seconds: -1.0)

    assert_not position.valid?
    assert_includes position.errors.attribute_names, :position_seconds
  end

  test "rejects a position greater than the song duration" do
    song = resumable_song # duration set to LONG_TRACK_THRESHOLD (1200)
    position = @user.playback_positions.build(song: song, position_seconds: song.duration + 0.1)

    assert_not position.valid?
    assert_includes position.errors.attribute_names, :position_seconds
  end

  test "accepts a valid position within the song duration on a resumable song" do
    song = resumable_song
    position = @user.playback_positions.build(song: song, position_seconds: 600.0)

    assert position.valid?, position.errors.full_messages.inspect
  end

  private

  # A resumable Song built from a fixture by lengthening it past the
  # Long_Track_Threshold (its album is classified :music, so duration alone
  # makes it resumable).
  def resumable_song
    song = songs(:ogg_sample)
    song.update!(duration: PlaybackPosition::LONG_TRACK_THRESHOLD)
    song
  end
end
