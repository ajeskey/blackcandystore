# frozen_string_literal: true

require "test_helper"

class DedupTest < ActiveSupport::TestCase
  test "a song can belong to a duplicate group" do
    group = DuplicateGroup.create!(logical_track_key: "flac_sample|artist1|album1|8.0")
    song = songs(:flac_sample)

    song.update!(duplicate_group: group)

    assert_equal group, song.reload.duplicate_group
    assert_includes group.reload.songs, song
  end

  test "a song has no duplicate group by default" do
    assert_nil songs(:mp3_sample).duplicate_group
  end

  test "destroying a duplicate group nullifies its songs' association" do
    group = DuplicateGroup.create!(logical_track_key: "key")
    song = songs(:flac_sample)
    song.update!(duplicate_group: group)

    group.destroy

    assert_nil song.reload.duplicate_group_id
  end

  test "a content fingerprint belongs to a song" do
    fingerprint = ContentFingerprint.create!(
      song: songs(:flac_sample),
      md5_hash: "flac_sample_md5_hash",
      normalized_key: "flac_sample|artist1|album1|8.0"
    )

    assert_equal songs(:flac_sample), fingerprint.song
    assert_equal fingerprint, songs(:flac_sample).reload.content_fingerprint
  end

  test "content fingerprint requires a song" do
    fingerprint = ContentFingerprint.new(md5_hash: "abc")

    assert_not fingerprint.valid?
  end

  # --- Deduplicator.fingerprint computation (task 18.2, Req 12.1) ---

  test "fingerprint persists md5_hash and normalized metadata key" do
    song = songs(:mp3_sample)

    fingerprint = Deduplicator.fingerprint(song)

    assert_equal song.md5_hash, fingerprint.md5_hash
    assert_equal(
      "mp3_sample|#{song.artist.name.downcase}|#{song.album.name.downcase}|8",
      fingerprint.normalized_key
    )
    assert_equal song, fingerprint.song
  end

  test "fingerprint persists exactly one ContentFingerprint per song and updates it" do
    song = songs(:mp3_sample)

    first = Deduplicator.fingerprint(song)
    assert_equal 1, ContentFingerprint.where(song_id: song.id).count

    # Re-running with unchanged data is idempotent: same record, same values.
    second = Deduplicator.fingerprint(song)
    assert_equal first.id, second.id
    assert_equal 1, ContentFingerprint.where(song_id: song.id).count
    assert_equal first.normalized_key, second.normalized_key

    # Changing metadata updates the same record's normalized key.
    song.update!(name: "Renamed Track")
    updated = Deduplicator.fingerprint(song)
    assert_equal first.id, updated.id
    assert_equal "renamed track|#{song.artist.name.downcase}|#{song.album.name.downcase}|8", updated.normalized_key
  end

  test "acoustic fingerprint is nil by default (feature flag off)" do
    fingerprint = Deduplicator.fingerprint(songs(:mp3_sample))

    assert_nil fingerprint.acoustic_fingerprint
  end

  test "acoustic fingerprint stays nil when flag enabled but no local file" do
    with_env("ENABLE_ACOUSTIC_FINGERPRINT" => "true") do
      song = songs(:mp3_sample)
      song.update_columns(file_path: "/nonexistent/path/to/file.mp3")

      fingerprint = Deduplicator.fingerprint(song)

      assert_nil fingerprint.acoustic_fingerprint
    end
  end

  test "normalized key downcases, strips, and collapses whitespace deterministically" do
    song = songs(:mp3_sample)
    song.update!(name: "  Hello   World  ")

    key = Deduplicator.normalized_key(song)

    assert_equal "hello world|#{song.artist.name.downcase}|#{song.album.name.downcase}|8", key
    # Deterministic: same input yields the same key every time.
    assert_equal key, Deduplicator.normalized_key(song)
  end

  test "normalized key rounds duration to whole seconds" do
    song = songs(:mp3_sample)
    song.update!(duration: 8.4)
    assert_equal "8", Deduplicator.normalized_key(song).split("|").last

    song.update!(duration: 8.6)
    assert_equal "9", Deduplicator.normalized_key(song).split("|").last
  end

  # --- Property: normalized_key is a deterministic pure function (Req 12.1) ---

  # Feature: multi-server-library-sharing, Property 16: Same-content classification is reflexive and symmetric
  test "normalized_key is deterministic across arbitrary metadata" do
    song = songs(:mp3_sample)

    # Generate alpha-only tokens (no "|" so the key structure stays stable),
    # then wrap them with irregular whitespace in the assertion block to
    # exercise the downcase/strip/collapse normalization.
    check_property do
      [
        sized(range(1, 8)) { string(:alpha) },
        sized(range(1, 8)) { string(:alpha) },
        sized(range(1, 8)) { string(:alpha) },
        sized(range(1, 8)) { string(:alpha) },
        range(0, 100000)
      ]
    end.check do |(word1, word2, artist_word, album_word, duration_ms)|
      song.name = "  #{word1}   #{word2}  "
      song.artist.name = " #{artist_word} "
      song.album.name = "#{album_word}  "
      song.duration = duration_ms / 1000.0

      first = Deduplicator.normalized_key(song)
      second = Deduplicator.normalized_key(song)

      assert_equal first, second
      # Structure invariant: exactly four "|"-separated components.
      assert_equal 4, first.split("|", -1).length
      # Duration component is the rounded whole-second value.
      assert_equal (duration_ms / 1000.0).round.to_s, first.split("|", -1).last
    end
  end

  # --- Deduplicator.same_content? classification (task 19.1) ---

  # Req 12.8: reflexive property.
  test "same_content? is reflexive" do
    Song.all.each do |song|
      assert Deduplicator.same_content?(song, song), "expected #{song.name} to be same content as itself"
    end
  end

  # Req 12.2: identical md5_hash => same content.
  test "same_content? is true for songs with identical md5_hash" do
    a = songs(:mp3_sample)
    b = songs(:flac_sample)
    # Same md5_hash in a different library (the cross-library dedup case).
    b.update!(md5_hash: a.md5_hash, library: libraries(:secondary_library))

    assert Deduplicator.same_content?(a, b)
  end

  # Req 12.1: matching Content_Fingerprint (same normalized metadata) => same content,
  # even when md5_hash values differ.
  test "same_content? is true for songs with matching fingerprint but different md5" do
    a = songs(:flac_sample)
    b = songs(:m4a_sample) # same artist1 / album1 / duration 8.0 as flac_sample
    b.update!(name: a.name)

    assert_not_equal a.md5_hash, b.md5_hash
    assert_equal Deduplicator.normalized_key(a), Deduplicator.normalized_key(b)
    assert Deduplicator.same_content?(a, b)
  end

  # Req 12.9: symmetric property, across matching and non-matching pairs.
  test "same_content? is symmetric" do
    a = songs(:mp3_sample)
    b = songs(:flac_sample)
    c = songs(:ogg_sample)
    # make a and b match by md5 (in a different library)
    b.update!(md5_hash: a.md5_hash, library: libraries(:secondary_library))

    assert_equal Deduplicator.same_content?(a, b), Deduplicator.same_content?(b, a)
    assert_equal Deduplicator.same_content?(a, c), Deduplicator.same_content?(c, a)
  end

  # Req 12.1: distinct content (different metadata and md5) is not the same content.
  test "same_content? is false for songs with different content" do
    a = songs(:mp3_sample)
    c = songs(:ogg_sample)

    assert_not_equal a.md5_hash, c.md5_hash
    assert_not_equal Deduplicator.normalized_key(a), Deduplicator.normalized_key(c)
    assert_not Deduplicator.same_content?(a, c)
  end

  # Acoustic fingerprints that differ (both present) block a fingerprint match
  # even when the normalized metadata is identical.
  test "same_content? distinguishes differing acoustic fingerprints" do
    a = songs(:flac_sample)
    b = songs(:m4a_sample)
    b.update!(name: a.name) # identical normalized_key

    ContentFingerprint.create!(song: a, md5_hash: a.md5_hash, normalized_key: Deduplicator.normalized_key(a), acoustic_fingerprint: "AAAA")
    ContentFingerprint.create!(song: b, md5_hash: b.md5_hash, normalized_key: Deduplicator.normalized_key(b), acoustic_fingerprint: "BBBB")

    assert_not Deduplicator.same_content?(a, b)

    # Same acoustic fingerprint => same content.
    b.content_fingerprint.update!(acoustic_fingerprint: "AAAA")
    assert Deduplicator.same_content?(a, b.reload)
  end

  # --- Deduplicator.group grouping (task 19.1) ---

  # Req 12.10: identical fingerprints land in the same Duplicate_Group.
  test "group places matching songs in the same duplicate group" do
    a = songs(:flac_sample)
    b = songs(:m4a_sample)
    b.update!(name: a.name) # identical normalized_key as a

    groups = Deduplicator.group([ a, b ])

    assert_equal 1, groups.length
    assert_equal a.reload.duplicate_group_id, b.reload.duplicate_group_id
    assert_not_nil a.duplicate_group_id
  end

  # Req 12.4: non-matching content lands in different Duplicate_Groups.
  test "group places distinct songs in different duplicate groups" do
    a = songs(:mp3_sample)
    c = songs(:ogg_sample)

    groups = Deduplicator.group([ a, c ])

    assert_equal 2, groups.length
    assert_not_equal a.reload.duplicate_group_id, c.reload.duplicate_group_id
  end

  # Req 12.3: a set of same-content songs collapses to a single Logical_Track.
  test "group unions songs linked transitively via md5 and fingerprint" do
    a = songs(:mp3_sample)
    b = songs(:flac_sample)
    c = songs(:ogg_sample)

    # a <-> b via md5 (different library), b <-> c via fingerprint => all one group.
    b.update!(md5_hash: a.md5_hash, library: libraries(:secondary_library))
    c.update!(name: b.name, artist: b.artist, album: b.album, duration: b.duration)

    groups = Deduplicator.group([ a, b, c ])

    assert_equal 1, groups.length
    group_ids = [ a, b, c ].map { |song| song.reload.duplicate_group_id }
    assert_equal 1, group_ids.uniq.length
  end

  test "group is idempotent and reuses duplicate group rows" do
    a = songs(:flac_sample)
    b = songs(:m4a_sample)
    b.update!(name: a.name)

    first = Deduplicator.group([ a, b ])
    count_after_first = DuplicateGroup.count
    second = Deduplicator.group([ a, b ])

    assert_equal first.map(&:id), second.map(&:id)
    assert_equal count_after_first, DuplicateGroup.count
  end

  test "group returns empty for no songs" do
    assert_equal [], Deduplicator.group([])
  end

  # --- Deduplicator.group_albums / group_artists (Req 12.5) ---

  test "group_albums groups albums by normalized name and artist" do
    a = albums(:album1)
    # A same-named album/artist in another library represents the same album.
    duplicate = Album.create!(name: "  ALBUM1 ", artist: a.artist, library: libraries(:secondary_library))
    other = albums(:album3)

    grouped = Deduplicator.group_albums([ a, duplicate, other ])

    key = Deduplicator.album_key(a)
    assert_equal 2, grouped.length
    assert_equal [ a, duplicate ].sort_by(&:id), grouped[key].sort_by(&:id)
    assert_includes grouped.values, [ other ]
  end

  test "group_artists groups artists by normalized name" do
    a = artists(:artist1)
    duplicate = Artist.create!(name: " ARTIST1 ", library: libraries(:secondary_library))
    other = artists(:artist2)

    grouped = Deduplicator.group_artists([ a, duplicate, other ])

    assert_equal 2, grouped.length
    assert_equal [ a, duplicate ].sort_by(&:id), grouped[Deduplicator.artist_key(a)].sort_by(&:id)
  end
end
