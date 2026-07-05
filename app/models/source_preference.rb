# frozen_string_literal: true

# Source_Preference resolver (Req 11, 12.6, 12.11).
#
# A Logical_Track can be reachable from more than one accessible source — a
# Song in the User's own Local_Library and/or copies in other libraries or on
# other servers. `SourcePreference.select` picks exactly one playable Song from
# a Duplicate_Group for a User, deterministically, so that Path_Resolver has a
# single copy to resolve a Resolved_Stream_Path for (Req 8.13, 12.6, 12.11).
#
# Determinism: the selection is a pure function of the candidate Songs, their
# availability, their quality signals, their owning libraries, and the User's
# Source_Preference. The same inputs always yield the same Song (Req 12.6).
#
# Selection rules:
#   * `prefer_own_server` — the copy in the User's own Local_Library when one is
#     available, otherwise the highest-quality available copy (Req 11.4, 11.6,
#     11.7).
#   * `prefer_highest_quality` — the highest-quality available copy ranked by
#     lossless status first, then bit depth, then bitrate (Req 11.5, 11.7).
#   * Ties under either preference are broken by choosing the copy in the User's
#     own Local_Library first, otherwise the copy with the lowest actual Library
#     identifier (Req 11.8).
#   * When no accessible copy remains, no Song is selected and the caller marks
#     the content unavailable (Req 11.9, 12.11).
#
# Quality is ranked by lossless status, then bit depth, then bitrate (Req 11.5).
# There is no stored `bitrate` column today; `Song#lossless?` and `Song#bit_depth`
# carry the available quality signal. `bitrate_for` reads a `bitrate` only if a
# Song exposes one, and otherwise treats it as unknown (0), so the ranking still
# degrades cleanly to lossless-then-bit-depth. The Library identifier tiebreak
# (Req 11.8) keeps the result fully deterministic regardless.
module SourcePreference
  DEFAULT_PREFERENCE = User::DEFAULT_SOURCE_PREFERENCE
  PREFER_OWN_SERVER = "prefer_own_server"
  PREFER_HIGHEST_QUALITY = "prefer_highest_quality"

  class << self
    # Select exactly one playable Song from a Duplicate_Group for a User.
    #
    # @param duplicate_group [DuplicateGroup, Enumerable<Song>] a Duplicate_Group
    #   or any collection of candidate Songs representing one Logical_Track.
    # @param user [User, nil] the User the selection is resolved for; its
    #   Source_Preference drives the ordering and its owned libraries define the
    #   "own copy" tiebreak.
    # @return [Song, nil] the selected Song, or nil when no accessible copy
    #   remains (Req 11.9, 12.11).
    def select(duplicate_group, user:)
      available = candidate_songs(duplicate_group).select { |song| available?(song) }
      return nil if available.empty?

      available.min_by { |song| ranking_key(song, user) }
    end

    private

    # Accept either a Duplicate_Group (which exposes its member Songs through
    # `songs`) or a raw collection of Songs.
    def candidate_songs(duplicate_group)
      if duplicate_group.respond_to?(:songs)
        duplicate_group.songs.to_a
      else
        Array(duplicate_group)
      end
    end

    # A copy is available when its Stream_Source can be resolved: a `local` Song
    # is always available, and a `remote` Song is available only through an
    # active Library_Connection. This delegates to the shared RemoteAvailability
    # predicate — the same predicate Path_Resolver uses — so source selection and
    # streaming path resolution can never disagree about availability (Req 11.3,
    # 11.9, 12.7).
    def available?(song)
      RemoteAvailability.available?(song)
    end

    # A deterministic ordering key: sorting ascending places the preferred copy
    # first. The leading components encode the active preference; the trailing
    # components encode the tiebreak (own library first, then lowest Library id),
    # so the total order is strict and the same inputs always select the same
    # Song (Req 11.4–11.8, 12.6).
    def ranking_key(song, user)
      if preference(user) == PREFER_HIGHEST_QUALITY
        [ *quality_key(song), *tiebreak_key(song, user) ]
      else
        # prefer_own_server: own copy dominates quality (Req 11.4, 11.7).
        [ own_rank(song, user), *quality_key(song), *tiebreak_key(song, user) ]
      end
    end

    # Quality ordering (best first): lossless before lossy, then higher bit
    # depth, then higher bitrate. Negated so a plain ascending sort ranks the
    # highest quality first (Req 11.5).
    def quality_key(song)
      [ song.lossless? ? 0 : 1, -bit_depth_for(song), -bitrate_for(song) ]
    end

    # Tiebreak ordering (Req 11.8): the copy in the User's own Local_Library
    # first, then the copy with the lowest actual Library identifier.
    def tiebreak_key(song, user)
      [ own_rank(song, user), library_id_for(song) ]
    end

    # 0 when the Song belongs to a Local_Library the User owns, 1 otherwise, so
    # ascending sort prefers the User's own copy (Req 11.4, 11.8).
    def own_rank(song, user)
      own_library?(song, user) ? 0 : 1
    end

    def own_library?(song, user)
      return false if user.nil?

      library = song.library
      library.present? && library.local? && library.owner_id == user.id
    end

    # The active Source_Preference for the User, defaulting to prefer_own_server
    # when there is no User or no configured value (Req 11.2).
    def preference(user)
      (user && user.source_preference) || DEFAULT_PREFERENCE
    end

    def bit_depth_for(song)
      song.bit_depth.to_i
    end

    # There is no stored bitrate today; use a Song-provided bitrate when one is
    # exposed and otherwise treat it as unknown (0) so the ranking falls back to
    # lossless-then-bit-depth (Req 11.5).
    def bitrate_for(song)
      return 0 unless song.respond_to?(:bitrate)

      song.bitrate.to_i
    rescue StandardError
      0
    end

    # A Song with no resolvable Library association sorts last on the id
    # tiebreak; a very large sentinel keeps the ordering total and deterministic.
    def library_id_for(song)
      song.library_id || Float::INFINITY
    end
  end
end
