# frozen_string_literal: true

require "test_helper"

class RadioStationTest < ActiveSupport::TestCase
  setup do
    @user = users(:visitor1) # owns default_library, where every song fixture lives
    @artist1 = artists(:artist1)
  end

  def build_station(name: "My Station", &block)
    station = RadioStation.new(name: name, user: @user)
    block&.call(station)
    station
  end

  test "is valid with a name and criteria that select at least one authorized song" do
    station = build_station do |s|
      s.station_source_criteria.build(criterion_type: "artist", artist: @artist1)
    end

    assert station.valid?, station.errors.full_messages.to_sentence
  end

  test "trims the name before validating length" do
    station = build_station(name: "  Jazz FM  ") do |s|
      s.station_source_criteria.build(criterion_type: "artist", artist: @artist1)
    end

    assert station.valid?
    assert_equal "Jazz FM", station.name
  end

  test "rejects a blank, whitespace-only, or over-255 name" do
    [ "", "   ", "a" * 256 ].each do |bad_name|
      station = build_station(name: bad_name) do |s|
        s.station_source_criteria.build(criterion_type: "artist", artist: @artist1)
      end

      assert_not station.valid?, "expected #{bad_name.inspect} to be rejected"
      assert station.errors.key?(:name)
    end
  end

  test "accepts a name whose trimmed length is exactly 255" do
    station = build_station(name: "a" * 255) do |s|
      s.station_source_criteria.build(criterion_type: "artist", artist: @artist1)
    end

    assert station.valid?
  end

  test "rejects a station whose criteria select zero songs" do
    station = build_station # no criteria at all

    assert_not station.valid?
    assert_includes station.errors[:base], "criteria select no playable songs"
  end

  test "eligible_songs is the criteria match intersected with authorized libraries" do
    station = build_station do |s|
      s.station_source_criteria.build(criterion_type: "artist", artist: @artist1)
    end
    station.save!

    expected = Song.where(artist: @artist1, library_id: @user.authorized_library_ids).ids.sort
    assert_equal expected, station.eligible_songs.ids.sort
    assert expected.any?
  end

  test "eligible_songs supports artist, song, and genre criteria combined" do
    song = songs(:ogg_sample) # artist2 / album3 (no genre)
    station = build_station do |s|
      s.station_source_criteria.build(criterion_type: "song", song: song)
      s.station_source_criteria.build(criterion_type: "genre", genre: "Rock")
    end
    station.save!

    rock_song_ids = Song.joins(:album).where(albums: { genre: "Rock" }).ids
    expected = (rock_song_ids + [ song.id ]).uniq.sort
    assert_equal expected, station.eligible_songs.ids.sort
  end

  test "excludes songs outside the owner's authorized libraries" do
    other_library = libraries(:secondary_library)
    foreign_artist = Artist.create!(name: "foreign", library: other_library)
    foreign_album = Album.create!(name: "foreign album", artist: foreign_artist, library: other_library)
    Song.create!(
      name: "foreign song", artist: foreign_artist, album: foreign_album, library: other_library,
      file_path: "/tmp/foreign.mp3", file_path_hash: "foreign_hash", md5_hash: "foreign_md5"
    )

    station = build_station do |s|
      s.station_source_criteria.build(criterion_type: "artist", artist: foreign_artist)
    end

    # visitor1 is not authorized for secondary_library, so the criteria select
    # zero playable songs and the station is rejected (Req 1.4, 1.3).
    assert_not station.valid?
    assert_empty station.eligible_songs
  end

  test "recomputes eligible_songs after a criteria change" do
    station = build_station do |s|
      s.station_source_criteria.build(criterion_type: "genre", genre: "Rock")
    end
    station.save!
    original = station.eligible_songs.ids.sort

    station.station_source_criteria.destroy_all
    station.station_source_criteria.create!(criterion_type: "artist", artist: artists(:artist2))
    station.reload

    updated = station.eligible_songs.ids.sort
    assert_not_equal original, updated
    assert_equal Song.where(artist: artists(:artist2), library_id: @user.authorized_library_ids).ids.sort, updated
  end

  test "belongs to a user and has the expected enum defaults" do
    station = build_station do |s|
      s.station_source_criteria.build(criterion_type: "artist", artist: @artist1)
    end
    station.save!

    assert_equal @user, station.user
    assert station.stopped?
    assert station.visibility_authenticated?
  end
end
