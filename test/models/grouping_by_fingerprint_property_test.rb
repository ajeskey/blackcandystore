# frozen_string_literal: true

require "test_helper"

# Property-based test for grouping Songs into Duplicate_Groups by content
# fingerprint (multi-server-library-sharing, Property 17 / Req 12.3, 12.4,
# 12.10).
#
# `Deduplicator.group(songs)` partitions Songs into Duplicate_Groups as the
# transitive closure of `same_content?`. Two Songs are the same content when
# they share an identical present `md5_hash` OR an identical normalized
# fingerprint ("name|artist|album|duration"). Grouping must therefore satisfy:
#
#   * (Req 12.3 / 12.10) every pair of Songs with an identical fingerprint ends
#     up with the SAME `duplicate_group_id`, and
#   * (Req 12.4) every pair of Songs with a non-matching fingerprint (and a
#     distinct `md5_hash`) ends up in DIFFERENT groups.
#
# Each generated Song is tagged with a "content class" label. Songs sharing a
# class are given identical fingerprint metadata (same name/artist/album/
# duration) but distinct `md5_hash` values — the clean "same content via
# fingerprint, not md5" case that also keeps the `(library_id, md5_hash)` unique
# index happy within a single library. Songs in different classes get distinct
# metadata AND distinct md5, so they must never be grouped together.
class GroupingByFingerprintPropertyTest < ActiveSupport::TestCase
  setup do
    @library = libraries(:default_library)
  end

  # Feature: multi-server-library-sharing, Property 17: Identical fingerprints are grouped together, distinct ones apart
  test "songs with identical fingerprints are grouped together and distinct ones apart" do
    check_property(iterations: 100) do
      # 2..8 songs, each assigned to one of a handful of content classes so
      # collisions (same class) and separations (different class) both occur.
      count = range(2, 8)
      Array.new(count) { range(0, 4) }
    end.check do |class_labels|
      reset_dedup_state

      songs = build_songs_for(class_labels)

      Deduplicator.group(songs)
      songs.each(&:reload)

      class_labels.each_index do |i|
        ((i + 1)...class_labels.length).each do |j|
          song_i = songs[i]
          song_j = songs[j]

          if class_labels[i] == class_labels[j]
            # Req 12.3 / 12.10: identical fingerprint => same Duplicate_Group.
            assert_not_nil song_i.duplicate_group_id,
              "expected grouped song to have a duplicate_group_id (classes=#{class_labels.inspect})"
            assert_equal song_i.duplicate_group_id, song_j.duplicate_group_id,
              "expected songs #{i} and #{j} (same class #{class_labels[i]}) to share a group " \
              "(classes=#{class_labels.inspect})"
          else
            # Req 12.4: non-matching fingerprint + distinct md5 => different groups.
            assert_not_equal song_i.duplicate_group_id, song_j.duplicate_group_id,
              "expected songs #{i} and #{j} (classes #{class_labels[i]} vs #{class_labels[j]}) " \
              "to be in different groups (classes=#{class_labels.inspect})"
          end
        end
      end
    end
  end

  private

  # Wipe all content between iterations so each generated set is grouped from a
  # clean slate. Ordered to respect foreign keys (children before parents).
  def reset_dedup_state
    ContentFingerprint.delete_all
    Song.delete_all
    Album.delete_all
    Artist.delete_all
    DuplicateGroup.delete_all
  end

  # Build one persisted Song per class label. Songs of the same class share the
  # exact same fingerprint metadata (via a shared Artist/Album keyed on the
  # class) but always get a distinct md5_hash so "same content" is decided by
  # the fingerprint, not by an md5 match.
  def build_songs_for(class_labels)
    class_metadata = {}

    class_labels.each_with_index.map do |label, index|
      artist, album = class_metadata[label] ||= build_class_metadata(label)

      Song.create!(
        name: "track#{label}",
        artist: artist,
        album: album,
        library: @library,
        duration: label + 1,
        md5_hash: "md5_#{index}",
        file_path: "/tmp/grouping_song_#{index}.mp3",
        file_path_hash: "grouping_fph_#{index}"
      )
    end
  end

  # Distinct Artist/Album per content class. Distinct class labels yield
  # distinct normalized names, so their normalized fingerprints never collide.
  def build_class_metadata(label)
    artist = Artist.create!(name: "artist#{label}", library: @library)
    album = Album.create!(name: "album#{label}", artist: artist, library: @library)
    [ artist, album ]
  end
end
