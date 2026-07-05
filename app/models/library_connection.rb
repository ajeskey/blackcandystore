# frozen_string_literal: true

# Library_Connection lives on the redeeming server. It stores how to reach and
# authenticate against a Remote_Library on another server (Req 5.2, 6.2).
#
# `grant_token` is the Bearer credential presented on every federation request
# to the hosting server. It is a secret and is stored encrypted at rest using
# Rails' encrypted attributes so a database compromise does not expose the
# credential in plaintext.
class LibraryConnection < ApplicationRecord
  belongs_to :user

  # The remote Library this connection reaches. A Remote_Library has exactly one
  # Library_Connection (Library `belongs_to :library_connection`), so this is a
  # one-to-one back-reference. It is the Catalog_Mirror's container: every
  # Mirrored_Song/Album/Artist for this connection lives in this Library, scoped
  # by `library_id` (Req 2.2, 2.3). Nil until the remote Library shell exists.
  #
  # Deleting a Library_Connection removes its Catalog_Mirror in full: the
  # dependent destroy tears down the associated remote Library, whose own
  # `before_destroy :destroy_scoped_content` removes every Mirrored_Song and
  # then the orphaned Mirrored_Albums/Mirrored_Artists scoped to that Library
  # (Req 9.3). Because that cascade is `library_id`-scoped, no other
  # connection's mirror is affected (Req 9.5).
  has_one :library, dependent: :destroy

  # A connection is active while the remote library is reachable and the grant
  # is valid. It becomes `unavailable` when the hosting server cannot be reached
  # and `revoked` once the hosting server reports the grant is no longer valid.
  enum :status, { active: "active", revoked: "revoked", unavailable: "unavailable" }, default: :active

  encrypts :grant_token
end
