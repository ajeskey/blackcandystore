# frozen_string_literal: true

require "test_helper"

# Canonical property test for Deduplicator.same_content? (Req 12.1, 12.2, 12.8,
# 12.9). Verifies that content classification is an equivalence-style relation:
#   * reflexive  (Req 12.8): same_content?(a, a) is always true
#   * symmetric  (Req 12.9): same_content?(a, b) == same_content?(b, a)
# and that the two matching signals classify identical content as the same:
#   * identical present md5_hash  => same content (Req 12.2)
#   * matching Content_Fingerprint => same content (Req 12.1)
class SameContentPropertyTest < ActiveSupport::TestCase
  # A monotonic sequence keeps md5_hash / file_path_hash values unique across
  # every generated iteration, so the (library_id, md5_hash) unique index never
  # collides even if a prior iteration's cleanup were to be interrupted.
  def next_seq
    @seq = (@seq || 0) + 1
  end

  # Build and persist a Song reusing the fixture artist/album (so the
  # normalized metadata key is driven entirely by the generated name/duration).
  def build_song(library:, name:, duration:, md5_hash:)
    seq = next_seq
    Song.create!(
      name: name,
      duration: duration,
      md5_hash: md5_hash,
      file_path: "/tmp/song_#{seq}.mp3",
      file_path_hash: "fph_#{seq}",
      artist: artists(:artist1),
      album: albums(:album1),
      library: library
    )
  end

  # Feature: multi-server-library-sharing, Property 16: Same-content classification is reflexive and symmetric
  test "same_content? is reflexive and symmetric and matches identical hash/fingerprint" do
    default_library = libraries(:default_library)
    secondary_library = libraries(:secondary_library)

    check_property do
      # Alpha-only tokens keep the "|"-delimited normalized key structure
      # intact; a bounded whole-second duration avoids rounding ambiguity.
      [
        sized(range(1, 10)) { string(:alpha) },
        range(1, 600)
      ]
    end.check do |(base_name, duration)|
      seq = next_seq
      created = []

      begin
        shared_md5 = "shared_md5_#{seq}"

        # song_a: the reference song.
        song_a = build_song(
          library: default_library,
          name: base_name,
          duration: duration,
          md5_hash: shared_md5
        )

        # song_md5dup: identical md5_hash, but DIFFERENT metadata, placed in a
        # DIFFERENT library since (library_id, md5_hash) is uniquely indexed.
        # The only reason it matches song_a is the shared md5_hash (Req 12.2).
        song_md5dup = build_song(
          library: secondary_library,
          name: "#{base_name}MD5DUP",
          duration: duration,
          md5_hash: shared_md5
        )

        # song_fpdup: identical normalized metadata (same fingerprint) as
        # song_a but a DIFFERENT md5_hash, so it matches only via the
        # Content_Fingerprint (Req 12.1).
        song_fpdup = build_song(
          library: default_library,
          name: base_name,
          duration: duration,
          md5_hash: "fp_md5_#{seq}"
        )

        # song_unrelated: different md5_hash AND different metadata, so it
        # shares no content with the others.
        song_unrelated = build_song(
          library: default_library,
          name: "#{base_name}UNREL",
          duration: duration + 3,
          md5_hash: "unrelated_md5_#{seq}"
        )

        created = [ song_a, song_md5dup, song_fpdup, song_unrelated ]

        # Req 12.8 — reflexivity: every song is the same content as itself.
        created.each do |song|
          assert Deduplicator.same_content?(song, song),
            "expected same_content?(#{song.name}, itself) to be true"
        end

        # Req 12.9 — symmetry: swapping arguments never changes the result,
        # across every ordered pair (matching and non-matching alike).
        created.each do |a|
          created.each do |b|
            assert_equal Deduplicator.same_content?(a, b),
              Deduplicator.same_content?(b, a),
              "expected same_content? to be symmetric for #{a.name} / #{b.name}"
          end
        end

        # Req 12.2 — identical present md5_hash => same content.
        assert Deduplicator.same_content?(song_a, song_md5dup),
          "expected songs sharing an md5_hash to be classified as same content"

        # Req 12.1 — matching Content_Fingerprint (identical normalized
        # metadata) => same content, even with differing md5_hash values.
        assert_not_equal song_a.md5_hash, song_fpdup.md5_hash
        assert_equal Deduplicator.normalized_key(song_a),
          Deduplicator.normalized_key(song_fpdup)
        assert Deduplicator.same_content?(song_a, song_fpdup),
          "expected songs with a matching fingerprint to be classified as same content"

        # Distinct content (different md5_hash and metadata) is NOT the same,
        # which keeps the generated set meaningful for the symmetry check.
        assert_not Deduplicator.same_content?(song_a, song_unrelated),
          "expected unrelated songs to not be classified as same content"
      ensure
        # Clean state between iterations so accumulated rows never leak across
        # generated examples.
        created.each(&:destroy)
      end
    end
  end
end
