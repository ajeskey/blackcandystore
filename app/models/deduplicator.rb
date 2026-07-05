# frozen_string_literal: true

require "shellwords"

# The Deduplicator identifies Songs across Libraries and Servers that represent
# the same underlying content (Req 12). This file defines the content
# fingerprinting used to match duplicates.
#
# Classification (`same_content?`) and grouping (`group`, `group_albums`,
# `group_artists`) are layered on top of the fingerprint computation: content
# equality is decided from a Song's `md5_hash` plus its Content_Fingerprint,
# and grouping is the transitive closure of that equivalence relation.
#
# Mirrored_Songs as remote copies (Req 11.2). A Mirrored_Song lives in a
# `kind: remote` Library and is grouped here exactly like any other copy of the
# same Logical_Track: `same_content?` compares content signatures (md5_hash +
# normalized metadata) and never inspects the owning Library's kind or its
# Library_Connection, so a Mirrored_Song lands in the same Duplicate_Group as a
# matching local Song. Grouping deliberately does NOT filter on availability:
# whether a Mirrored_Song's Library_Connection is currently active is a
# selection concern, not a content-identity one, and dropping a temporarily
# unavailable copy from its group would make grouping non-deterministic and
# non-idempotent (Req 12.8–12.10). The "available only while its
# Library_Connection is active" treatment (Req 11.2, 11.3) is applied downstream
# by `SourcePreference.select`, which filters group members through the shared
# `RemoteAvailability` predicate before choosing a copy — so a Mirrored_Song is
# grouped as a remote copy here and treated as reachable only while active there.
module Deduplicator
  # ENV flag that opts in to computing the optional acoustic fingerprint.
  # Acoustic fingerprinting relies on the `fpcalc` (Chromaprint) native binary,
  # which is a Medium-risk native dependency. It is therefore pluggable and
  # OFF by default: unless this flag is enabled AND the binary is available on
  # PATH, `acoustic_fingerprint` stays nil and no native dependency is required.
  ACOUSTIC_FINGERPRINT_ENV = "ENABLE_ACOUSTIC_FINGERPRINT"

  # Name of the acoustic fingerprint binary (Chromaprint's fpcalc).
  FPCALC_BINARY = "fpcalc"

  class << self
    # Compute and persist the ContentFingerprint for a Song.
    #
    # The fingerprint is a pure, deterministic function of the Song's data
    # (`md5_hash` plus normalized core metadata), except for the optional
    # acoustic fingerprint which is feature-flagged and off by default.
    #
    # Creating or updating is idempotent: calling this repeatedly for a Song
    # with unchanged data yields the same stored values.
    #
    # @param song [Song]
    # @return [ContentFingerprint] the persisted fingerprint for the Song.
    def fingerprint(song)
      values = fingerprint_values(song)

      content_fingerprint = ContentFingerprint.find_or_initialize_by(song_id: song.id)
      content_fingerprint.assign_attributes(values)
      content_fingerprint.save!
      content_fingerprint
    end

    # Build the fingerprint attribute values for a Song without persisting.
    # Kept separate so callers (and tests) can inspect the pure computation.
    #
    # @param song [Song]
    # @return [Hash] `{ md5_hash:, normalized_key:, acoustic_fingerprint: }`
    def fingerprint_values(song)
      {
        md5_hash: song.md5_hash,
        normalized_key: normalized_key(song),
        acoustic_fingerprint: acoustic_fingerprint(song)
      }
    end

    # Deterministic normalized metadata key: "name|artist|album|duration".
    #
    # Each metadata component is normalized (see #normalize) and the duration is
    # rounded to whole seconds so that trivial encoding jitter does not defeat
    # matching. The result is a pure function of the Song's stored metadata.
    #
    # @param song [Song]
    # @return [String]
    def normalized_key(song)
      [
        normalize(song.name),
        normalize(song.artist&.name),
        normalize(song.album&.name),
        normalize_duration(song.duration)
      ].join("|")
    end

    # Decide whether two Songs represent the same underlying content (Req 12.1,
    # 12.2). Two Songs are the same content iff EITHER:
    #   * they share an identical, present `md5_hash`, OR
    #   * their Content_Fingerprints match: identical `normalized_key`, and
    #     (when BOTH have an acoustic fingerprint present) identical
    #     `acoustic_fingerprint`.
    #
    # This relation is an equivalence relation over Songs:
    #   * REFLEXIVE (Req 12.8): a Song always shares its own `normalized_key`
    #     (and md5_hash), so `same_content?(a, a)` is always true.
    #   * SYMMETRIC (Req 12.9): every underlying comparison is equality of the
    #     two Songs' signatures, so swapping the arguments cannot change the
    #     result.
    #
    # @param a [Song]
    # @param b [Song]
    # @return [Boolean]
    def same_content?(a, b)
      return true if a.equal?(b)

      signature_a = content_signature(a)
      signature_b = content_signature(b)

      same_md5?(signature_a, signature_b) ||
        same_fingerprint?(signature_a, signature_b)
    end

    # Partition Songs into Duplicate_Groups (Req 12.3, 12.4, 12.10).
    #
    # Songs that are `same_content?` land in the same group and Songs with
    # non-matching content land in different groups. Grouping is the transitive
    # closure of `same_content?` (computed with union-find), which keeps the
    # partition well-defined even when two Songs are linked only indirectly
    # (e.g. A shares an md5_hash with B while B shares a fingerprint with C).
    #
    # For each resulting component a `DuplicateGroup` is found-or-created by a
    # deterministic `logical_track_key` derived from the component's canonical
    # (lowest-id) representative, and every persisted member Song is assigned to
    # it. The call is idempotent: re-grouping the same Songs reuses the same
    # DuplicateGroup rows.
    #
    # @param songs [Enumerable<Song>]
    # @return [Array<DuplicateGroup>] one group per component, ordered
    #   deterministically by the lowest member sort key.
    def group(songs)
      members = Array(songs).uniq
      return [] if members.empty?

      components = connected_components(members)

      components
        .sort_by { |component| component.map { |song| song_sort_key(song) }.min }
        .map { |component| assign_duplicate_group(component) }
    end

    # Group Albums across Libraries that share identifying metadata (Req 12.5):
    # same normalized album name AND normalized artist name. Returns a mapping
    # of normalized key to the Albums sharing it, so callers can treat Albums
    # from different Libraries/Servers as one logical Album.
    #
    # @param albums [Enumerable<Album>]
    # @return [Hash{String => Array<Album>}]
    def group_albums(albums)
      Array(albums).group_by { |album| album_key(album) }
    end

    # Group Artists across Libraries that share identifying metadata (Req 12.5):
    # same normalized artist name. Returns a mapping of normalized key to the
    # Artists sharing it.
    #
    # @param artists [Enumerable<Artist>]
    # @return [Hash{String => Array<Artist>}]
    def group_artists(artists)
      Array(artists).group_by { |artist| artist_key(artist) }
    end

    # Deterministic normalized identity key for an Album (Req 12.5):
    # "normalized name|normalized artist name".
    #
    # @param album [Album]
    # @return [String]
    def album_key(album)
      [ normalize(album.name), normalize(album.artist&.name) ].join("|")
    end

    # Deterministic normalized identity key for an Artist (Req 12.5).
    #
    # @param artist [Artist]
    # @return [String]
    def artist_key(artist)
      normalize(artist.name)
    end

    private

    # The content signature compared by `same_content?`. Prefers the persisted
    # Content_Fingerprint when present (so any stored acoustic fingerprint is
    # honored) and otherwise falls back to the pure, deterministic computation.
    def content_signature(song)
      fingerprint = song.respond_to?(:content_fingerprint) ? song.content_fingerprint : nil

      if fingerprint
        {
          md5_hash: fingerprint.md5_hash,
          normalized_key: fingerprint.normalized_key,
          acoustic_fingerprint: fingerprint.acoustic_fingerprint
        }
      else
        fingerprint_values(song)
      end
    end

    # md5 match: both signatures carry the same, present md5_hash. The
    # both-present requirement keeps blank hashes from matching each other.
    def same_md5?(a, b)
      a[:md5_hash].present? && a[:md5_hash] == b[:md5_hash]
    end

    # Content_Fingerprint match: identical (present) normalized_key, and — only
    # when BOTH signatures carry an acoustic fingerprint — identical acoustic
    # fingerprint. A missing acoustic fingerprint on either side never blocks a
    # match, so the check reduces to normalized metadata alone by default.
    def same_fingerprint?(a, b)
      return false unless a[:normalized_key].present?
      return false unless a[:normalized_key] == b[:normalized_key]

      if a[:acoustic_fingerprint].present? && b[:acoustic_fingerprint].present?
        a[:acoustic_fingerprint] == b[:acoustic_fingerprint]
      else
        true
      end
    end

    # Union-find over the `same_content?` relation, returning the list of
    # connected components (each an array of Songs).
    def connected_components(members)
      parent = (0...members.length).to_a

      find = lambda do |i|
        root = i
        root = parent[root] while parent[root] != root
        while parent[i] != root
          parent[i], i = root, parent[i]
        end
        root
      end

      members.each_index do |i|
        ((i + 1)...members.length).each do |j|
          next unless same_content?(members[i], members[j])

          root_i = find.call(i)
          root_j = find.call(j)
          parent[root_i] = root_j if root_i != root_j
        end
      end

      buckets = Hash.new { |hash, key| hash[key] = [] }
      members.each_index { |i| buckets[find.call(i)] << members[i] }
      buckets.values
    end

    # Find-or-create the DuplicateGroup for one component and assign its
    # persisted member Songs to it. The logical_track_key is derived from the
    # component's canonical (lowest sort key) representative so distinct
    # components yield distinct keys and the assignment is idempotent.
    def assign_duplicate_group(component)
      representative = component.min_by { |song| song_sort_key(song) }
      signature = content_signature(representative)
      logical_track_key = [ signature[:normalized_key], signature[:acoustic_fingerprint] ].join("::")

      group = DuplicateGroup.find_or_create_by!(logical_track_key: logical_track_key)

      component.each do |song|
        song.update!(duplicate_group: group) if song.respond_to?(:persisted?) && song.persisted?
      end

      group
    end

    # Deterministic ordering key for a Song: its persisted id when available,
    # otherwise a stable per-object fallback.
    def song_sort_key(song)
      (song.respond_to?(:id) && song.id) || song.object_id
    end

    # Normalize a free-text metadata value deterministically:
    #   * treat nil as empty
    #   * downcase
    #   * strip leading/trailing whitespace
    #   * collapse any internal run of whitespace to a single space
    def normalize(value)
      value.to_s.downcase.strip.gsub(/\s+/, " ")
    end

    # Normalize a duration (seconds, possibly float) to a stable string by
    # rounding to the nearest whole second. nil/blank durations normalize to 0.
    def normalize_duration(duration)
      duration.to_f.round.to_s
    end

    # Optionally compute the acoustic (Chromaprint) fingerprint for a Song.
    #
    # Returns nil unless the feature flag is enabled AND the `fpcalc` binary is
    # available AND the Song has a readable local file. Any failure computing
    # the fingerprint degrades gracefully to nil so dedup still works on
    # md5_hash + normalized metadata alone.
    #
    # @param song [Song]
    # @return [String, nil]
    def acoustic_fingerprint(song)
      return nil unless acoustic_fingerprinting_enabled?

      file_path = song.file_path
      return nil if file_path.blank? || !File.exist?(file_path)

      compute_acoustic_fingerprint(file_path)
    end

    # Whether acoustic fingerprinting is turned on and usable in this
    # environment: the ENV flag must be truthy and `fpcalc` must be on PATH.
    def acoustic_fingerprinting_enabled?
      flag_enabled? && fpcalc_available?
    end

    def flag_enabled?
      value = ENV[ACOUSTIC_FINGERPRINT_ENV].to_s.strip.downcase
      %w[1 true yes on].include?(value)
    end

    # Detect the fpcalc binary without raising if it is absent.
    def fpcalc_available?
      path = ENV["PATH"].to_s
      path.split(File::PATH_SEPARATOR).any? do |dir|
        File.executable?(File.join(dir, FPCALC_BINARY))
      end
    end

    # Run fpcalc and parse its FINGERPRINT= line. Returns nil on any failure.
    def compute_acoustic_fingerprint(file_path)
      output = `#{FPCALC_BINARY} #{Shellwords.escape(file_path)} 2>/dev/null`
      return nil unless $?.success?

      match = output[/^FINGERPRINT=(.+)$/, 1]
      match&.strip.presence
    rescue StandardError
      nil
    end
  end
end
