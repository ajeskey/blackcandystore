# frozen_string_literal: true

# RemoteAvailability is the single shared source of truth for "is this song
# currently reachable" on the redeeming side (Req 11.2, 11.3).
#
# Both Path_Resolver (path resolution) and Source_Preference (source selection)
# consult this predicate so the two can never disagree: a copy that is
# unavailable for selection is unavailable for resolution and vice versa. Browse
# visibility applies the same rule, keeping browse, path resolution, and source
# selection consistent.
#
# A local Song (including one whose Library association cannot be determined) is
# always available. A Mirrored_Song lives in a Remote_Library and is available
# only while that library's Library_Connection is present and active — a
# missing, revoked, or unavailable connection makes it unavailable (Req 11.2).
module RemoteAvailability
  # @param song [#library] a Song (or any record exposing a `library`).
  # @return [Boolean] whether the record is currently reachable.
  def self.available?(song)
    library = song.library
    return true unless library&.remote?

    connection = library.library_connection
    connection.present? && connection.active?
  end
end
