# frozen_string_literal: true

# Shared browse/search/list scoping for content controllers.
#
# Browsing, searching, and listing must only ever return content from the
# current User's Active_Library and must exclude the content of every other
# Library (Req 3.2). When the User has access to zero Libraries there is no
# Active_Library, and every scoped query returns nothing (Req 3.7).
#
# Controllers that list `Song`/`Album`/`Artist` content wrap their base
# relation with `scoped_to_active_library` so the restriction is applied
# consistently in one place. The underlying `in_library` scope lives on
# `LibraryScopedConcern`, shared by all three content models.
module LibraryScoping
  extend ActiveSupport::Concern

  private

  # Restrict a `Song`/`Album`/`Artist` class or relation to the current User's
  # browsable Active_Library. Resolves to nil when there is no signed-in user,
  # when the User has access to zero Libraries, or when the Active_Library is a
  # Remote_Library whose connection is no longer active, in which case
  # `in_library` yields an empty relation (Req 3.2, 3.7, 9.2, 11.3).
  def scoped_to_active_library(relation)
    relation.in_library(browsable_active_library)
  end

  # The current User's Active_Library, but only while its Catalog_Mirror is
  # still browsable. A Local_Library is always browsable; a Remote_Library is
  # browsable only while its Library_Connection is present and active, so once a
  # connection's status becomes `revoked` or `unavailable` its mirror stops
  # being served for browsing, searching, and listing (Req 9.2, 11.3). This is
  # the same active-connection predicate `RemoteAvailability` and the
  # authorized-libraries helper apply, keeping browse visibility, path
  # resolution, and source selection consistent. Returns nil when there is no
  # browsable Active_Library.
  def browsable_active_library
    library = Current.user&.active_library
    return library unless library&.remote?

    connection = library.library_connection
    (connection.present? && connection.active?) ? library : nil
  end
end
