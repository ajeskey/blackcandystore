# frozen_string_literal: true

require "test_helper"

# Property-based tests for the RadioStation validation seam of the
# radio-party-colisten feature (design Properties 1, 2, and 3).
#
# These exercise the pure RadioStation model logic — the derived eligible-song
# intersection, the "selects at least one authorized song" acceptance rule, and
# the name-length validity rule — directly, without the Broadcaster or any
# controller. Each iteration builds an isolated dataset of authorized and
# unauthorized libraries/songs so the authorization intersection is genuinely
# exercised.
#
# A song's eligibility is governed by:
#   * its authorization: a song is authorized iff it lives in a Library the
#     owning User is authorized to access (here, a local Library the User owns,
#     via User#authorized_library_ids), and
#   * whether it is selected by the station's Station_Source_Criteria (by
#     artist, by specific song, or by the album's genre).
#
# Because each generated song is given its own Artist and Album, selecting a
# song's artist selects exactly that song, which lets the masks below describe
# an arbitrary criteria set deterministically (and thus shrinkably).
class RadioStationPropertyTest < ActiveSupport::TestCase
  # A readable directory so freshly created local libraries pass media-path
  # validation; the fixtures directory always exists.
  MEDIA_PATH = Rails.root.join("test", "fixtures", "files").to_s
  # The genre value pool. Genre criteria are drawn from this fixed set and each
  # song is assigned one of these on its album.
  GENRES = %w[rock jazz pop folk].freeze
  GENRE_COUNT = GENRES.length
  # A genre value deliberately outside GENRES so an anchor song can never be
  # matched by a generated genre criterion (which only draws from GENRES).
  ANCHOR_GENRE = "anchor-only-genre"

  setup do
    @seq = 0
    @fixture_library_ids = [ libraries(:default_library).id, libraries(:secondary_library).id ]
  end

  # Feature: radio-party-colisten, Property 1: Eligible songs are exactly the authorized intersection
  test "eligible songs equal the criteria-matched songs intersected with the owner's authorized libraries, excluding every unauthorized song, and recompute after a criteria change" do
    check_property(iterations: 100) do
      # A dataset of songs, each either authorized (owned library) or not, with
      # an assigned genre; plus criteria masks selecting arbitrary subsets by
      # specific song, by that song's artist, and by genre value.
      n = range(1, 6)
      songs_spec = Array.new(n) { [ choose(true, false), range(0, GENRE_COUNT - 1) ] }
      sel_song = Array.new(n) { choose(true, false) }
      sel_artist = Array.new(n) { choose(true, false) }
      sel_genre = Array.new(GENRE_COUNT) { choose(true, false) }

      [ songs_spec, sel_song, sel_artist, sel_genre ]
    end.check do |(songs_spec, sel_song, sel_artist, sel_genre)|
      reset_dataset!
      owner, other = build_owner_and_other

      songs = build_songs(owner, other, songs_spec)

      station = RadioStation.new(user: owner, name: "Station-#{next_seq}")
      apply_criteria(station, songs, sel_song, sel_artist, sel_genre)

      # Expected = every song that (is matched by any criterion) AND (is
      # authorized). An unauthorized song is never eligible even when matched.
      expected = matched_authorized_ids(songs, sel_song, sel_artist, sel_genre)
      unauthorized_ids = songs.reject { |s| s[:authorized] }.map { |s| s[:id] }.to_set

      eligible = station.eligible_songs.pluck(:id).to_set

      assert_equal expected, eligible,
        "eligible songs must equal the criteria-matched authorized intersection"
      assert (eligible & unauthorized_ids).empty?,
        "no unauthorized song may ever be eligible (leaked: #{(eligible & unauthorized_ids).to_a})"

      # Req 1.5: recomputation reflects updated criteria. Replace the criteria
      # with a single artist criterion for the first song and re-derive.
      first = songs.first
      station.station_source_criteria = []
      station.station_source_criteria.build(criterion_type: "artist", artist_id: first[:artist_id])

      expected_after = first[:authorized] ? Set[first[:id]] : Set.new
      assert_equal expected_after, station.eligible_songs.pluck(:id).to_set,
        "eligible songs must be recomputed from the updated criteria"
    end
  end

  # Feature: radio-party-colisten, Property 2: A station is accepted iff it selects at least one authorized Song
  test "create and update of criteria succeed iff the eligible set is non-empty, and a rejected operation leaves any existing station and its criteria unchanged" do
    check_property(iterations: 100) do
      n = range(1, 6)
      songs_spec = Array.new(n) { [ choose(true, false), range(0, GENRE_COUNT - 1) ] }
      sel_song = Array.new(n) { choose(true, false) }
      sel_artist = Array.new(n) { choose(true, false) }
      sel_genre = Array.new(GENRE_COUNT) { choose(true, false) }

      [ songs_spec, sel_song, sel_artist, sel_genre ]
    end.check do |(songs_spec, sel_song, sel_artist, sel_genre)|
      reset_dataset!
      owner, other = build_owner_and_other

      songs = build_songs(owner, other, songs_spec)
      specs = criteria_specs(songs, sel_song, sel_artist, sel_genre)
      expected_nonempty = matched_authorized_ids(songs, sel_song, sel_artist, sel_genre).any?

      # --- create path ---
      created = RadioStation.new(user: owner, name: "Create-#{next_seq}")
      specs.each { |spec| created.station_source_criteria.build(spec) }
      saved = created.save

      assert_equal expected_nonempty, saved,
        "create succeeds iff the criteria select at least one authorized song"
      if expected_nonempty
        assert created.persisted?
      else
        assert_not created.persisted?, "a rejected create must persist no station"
        assert created.errors[:base].any? { |m| m.include?("no playable songs") },
          "a rejected create must return the no-playable-songs validation error"
      end

      # --- update path (starts from a known-valid station) ---
      anchor = build_song(owner, genre: ANCHOR_GENRE, authorized: true)
      baseline = RadioStation.new(user: owner, name: "Baseline-#{next_seq}")
      baseline.station_source_criteria.build(criterion_type: "artist", artist_id: anchor[:artist_id])
      baseline.save!
      original = criteria_tuples(baseline)

      updated = update_criteria(baseline, specs)

      assert_equal expected_nonempty, updated,
        "an update succeeds iff the new criteria select at least one authorized song"

      baseline.reload
      if expected_nonempty
        assert_equal spec_tuples(specs), criteria_tuples(baseline),
          "a successful update replaces the criteria with the new set"
      else
        assert_equal original, criteria_tuples(baseline),
          "a rejected update leaves the existing station's criteria unchanged"
      end
    end
  end

  # Feature: radio-party-colisten, Property 3: Station name validity
  test "a name is accepted iff its whitespace-trimmed length is 1..255, and a rejected name leaves any existing station unchanged" do
    check_property(iterations: 100) do
      # A core of non-whitespace characters of a chosen length (around the 1 and
      # 255 boundaries and beyond), optionally wrapped in leading/trailing
      # whitespace so blank and whitespace-only names are covered.
      core_len = choose(0, 1, 2, 10, 254, 255, 256, 300)
      lead = choose(0, 1, 2)
      trail = choose(0, 1, 2)
      core_char = choose("a", "Z", "7", "é")

      [ core_len, lead, trail, core_char ]
    end.check do |(core_len, lead, trail, core_char)|
      reset_dataset!
      owner, = build_owner_and_other

      # A single authorized song + an artist criterion so the eligible set is
      # always non-empty; the name is therefore the only validation in play.
      anchor = build_song(owner, genre: ANCHOR_GENRE, authorized: true)

      name = (" " * lead) + (core_char * core_len) + (" " * trail)
      expected_valid = core_len.between?(1, 255)

      # --- create path ---
      created = RadioStation.new(user: owner, name: name)
      created.station_source_criteria.build(criterion_type: "artist", artist_id: anchor[:artist_id])
      saved = created.save

      assert_equal expected_valid, saved,
        "a name is accepted iff its trimmed length is between 1 and 255 (len=#{core_len})"
      unless expected_valid
        assert_not created.persisted?, "a rejected name must persist no station"
        assert created.errors[:name].any?, "a rejected name must return a name validation error"
      end

      # --- rename path (starts from a known-valid station) ---
      existing = RadioStation.new(user: owner, name: "Existing-#{next_seq}")
      existing.station_source_criteria.build(criterion_type: "artist", artist_id: anchor[:artist_id])
      existing.save!
      original_name = existing.name

      existing.name = name
      renamed = existing.save

      assert_equal expected_valid, renamed,
        "a rename is accepted iff the new name's trimmed length is between 1 and 255"

      existing.reload
      if expected_valid
        assert_equal name.strip, existing.name, "a valid rename persists the trimmed name"
      else
        assert_equal original_name, existing.name, "a rejected rename leaves the existing name unchanged"
      end
    end
  end

  private

  def next_seq
    @seq += 1
  end

  # Wipe all station/criteria/content and every non-fixture library so each
  # iteration observes only the dataset it builds.
  def reset_dataset!
    StationSourceCriterion.delete_all
    RadioStation.delete_all
    Song.delete_all
    Album.delete_all
    Artist.delete_all
    Library.where.not(id: @fixture_library_ids).delete_all
  end

  # A fresh owning User (whose owned local libraries are its authorized set) and
  # a separate User used to hold unauthorized libraries.
  def build_owner_and_other
    owner = User.create!(email: "proprs-owner-#{SecureRandom.uuid}@example.com", password: "foobar123")
    other = User.create!(email: "proprs-other-#{SecureRandom.uuid}@example.com", password: "foobar123")
    [ owner, other ]
  end

  # Materialize songs_spec into rows. Authorized songs land in a library owned by
  # `owner`; unauthorized songs land in a library owned by `other`. Returns a
  # list of { id:, artist_id:, genre_idx:, authorized: } describing each song in
  # generation order.
  def build_songs(owner, other, songs_spec)
    auth_library = Library.create!(name: "PropRS-Auth-#{next_seq}", kind: "local", media_path: MEDIA_PATH, owner: owner)
    unauth_library = Library.create!(name: "PropRS-Unauth-#{next_seq}", kind: "local", media_path: MEDIA_PATH, owner: other)

    songs_spec.map do |(authorized, genre_idx)|
      library = authorized ? auth_library : unauth_library
      row = build_song(nil, genre: GENRES[genre_idx], authorized: authorized, library: library)
      row.merge(genre_idx: genre_idx)
    end
  end

  # Create one Artist/Album/Song triad in `library` (or a fresh owned library
  # when none is given, used for the anchor song). Returns
  # { id:, artist_id:, authorized: }.
  def build_song(owner, genre:, authorized:, library: nil)
    library ||= Library.create!(name: "PropRS-Auth-#{next_seq}", kind: "local", media_path: MEDIA_PATH, owner: owner)
    n = next_seq
    artist = Artist.create!(name: "Artist-#{n}", library: library)
    album = Album.create!(name: "Album-#{n}", artist: artist, library: library, genre: genre)
    song = Song.create!(
      name: "Song-#{n}",
      file_path: "/tmp/proprs-song-#{n}.mp3",
      file_path_hash: "fph-#{n}",
      md5_hash: "md5-#{n}",
      library: library,
      album: album,
      artist: artist
    )

    { id: song.id, artist_id: artist.id, authorized: authorized }
  end

  # Build the criteria described by the masks onto `station` (in memory).
  def apply_criteria(station, songs, sel_song, sel_artist, sel_genre)
    criteria_specs(songs, sel_song, sel_artist, sel_genre).each do |spec|
      station.station_source_criteria.build(spec)
    end
  end

  # The criterion attribute hashes described by the masks, in a stable order:
  # genre criteria first, then per-song song/artist criteria.
  def criteria_specs(songs, sel_song, sel_artist, sel_genre)
    specs = []
    GENRES.each_with_index do |genre, gi|
      specs << { criterion_type: "genre", genre: genre } if sel_genre[gi]
    end
    songs.each_with_index do |song, i|
      specs << { criterion_type: "song", song_id: song[:id] } if sel_song[i]
      specs << { criterion_type: "artist", artist_id: song[:artist_id] } if sel_artist[i]
    end
    specs
  end

  # The set of song ids that are both matched by the criteria and authorized.
  def matched_authorized_ids(songs, sel_song, sel_artist, sel_genre)
    songs.each_with_index.filter_map do |song, i|
      matched = sel_song[i] || sel_artist[i] || sel_genre[song[:genre_idx]]
      song[:id] if matched && song[:authorized]
    end.to_set
  end

  # Transactionally replace a persisted station's criteria with `specs`. Returns
  # true iff the save succeeds; on failure the transaction rolls back so the
  # station's existing criteria are left untouched.
  def update_criteria(station, specs)
    success = false
    RadioStation.transaction do
      station.station_source_criteria.destroy_all
      specs.each { |spec| station.station_source_criteria.build(spec) }
      success = station.save
      raise ActiveRecord::Rollback unless success
    end
    success
  end

  def criteria_tuples(station)
    station.station_source_criteria.pluck(:criterion_type, :artist_id, :song_id, :genre).to_set
  end

  def spec_tuples(specs)
    specs.map { |s| [ s[:criterion_type], s[:artist_id], s[:song_id], s[:genre] ] }.to_set
  end
end
