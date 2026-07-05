# frozen_string_literal: true

# Authorized_Content: the content a connecting Media_Client (DAAP/RSP),
# authenticated as a User account, is allowed to browse and download-and-play.
#
# Per Req 15.8 and 15.10 (Property 22) the DAAP_Service and RSP_Service restrict
# what they serve to the Local_Library content the account is authorized to
# access and SHALL NOT serve Remote_Library content. This selects exactly that
# set: the Songs, Albums, and Artists belonging to the LOCAL libraries within
# the account's browsing-authorized library set.
#
# The authorized library set is derived from `User#authorized_library_ids` — the
# SAME derivation the LibraryAccess controller concern uses for browsing and
# streaming — then filtered to local libraries so remote content is excluded
# (Req 15.8, 15.9, 15.10). Because authorization is recomputed from the user's
# current libraries on each call, revoking an account's access to a
# Local_Library immediately removes that library's content from the served set
# (Req 15.9).
#
# A user authorized to zero local libraries gets empty sets. The pure
# content-selection logic here is what DAAP_Service/RSP_Service (task 29.1)
# serve; Property 22 (task 28.3) asserts the served set equals exactly this set.
class AuthorizedContent
  def self.for(user)
    new(user)
  end

  def initialize(user)
    @library_ids = authorized_local_library_ids(user)
  end

  # The Songs belonging to the local libraries the user is authorized to access.
  def songs
    Song.where(library_id: @library_ids)
  end

  # The Albums belonging to the local libraries the user is authorized to access.
  def albums
    Album.where(library_id: @library_ids)
  end

  # The Artists belonging to the local libraries the user is authorized to access.
  def artists
    Artist.where(library_id: @library_ids)
  end

  private

  # The ids of the LOCAL libraries within the user's browsing-authorized set.
  # Filtering the shared authorized set to local guarantees no Remote_Library is
  # ever included (Req 15.8, 15.10). A nil user (unauthenticated) and a user
  # authorized to no libraries both resolve to an empty set.
  def authorized_local_library_ids(user)
    return [] if user.nil?

    Library.local.where(id: user.authorized_library_ids).ids
  end
end
