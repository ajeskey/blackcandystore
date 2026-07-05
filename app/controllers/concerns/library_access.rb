# frozen_string_literal: true

# Library_Access_Controller (browsing/selection half).
#
# Centralizes the authorization rules for reading a Library's content and for
# selecting an Active_Library. This is the controller-side counterpart to the
# per-user `accessible_libraries` helper on `User`; controllers include this
# concern and ask it whether a given user may reach a given library.
#
# The federation half (`authorize_grant!`) authorizes cross-server requests for
# Remote_Library content presented as a Bearer grant token.
module LibraryAccess
  extend ActiveSupport::Concern

  private

  # Authorize a cross-server request for a Remote_Library's content.
  #
  # The redeemer presents the plaintext grant token as a Bearer credential and
  # names the local `library_id` it wants to reach. This resolves that
  # credential to an Access_Grant and authorizes it with defense-in-depth: a
  # credential match is necessary but never sufficient (Req 6.8). Every failure
  # path raises `BlackCandy::Forbidden`, which renders an explicit authorization
  # error body rather than dropping the request silently (Req 6.4). On success
  # the matched Access_Grant is returned so the caller can serve content.
  def authorize_grant!(presented_token, library_id)
    # Hash the presented token and look up the matching grant with a
    # constant-time compare. No match rejects the request regardless of the
    # outcome of any other check (Req 6.6, and never a silent drop, Req 6.4).
    grant = AccessGrant.find_by_token(presented_token)
    raise BlackCandy::Forbidden if grant.nil?

    # A matched grant authorizes content only while it is active and not
    # expired; revoked or expired grants are rejected with an explicit
    # authorization error (Req 6.5, 7.3, 7.4).
    raise BlackCandy::Forbidden unless grant.usable?

    # Defense-in-depth: the grant must reference the requested library, and that
    # library must still exist and be local on this hosting server. The
    # credential match alone is never sufficient to authorize the request
    # (Req 6.8).
    library = Library.local.find_by(id: library_id)
    raise BlackCandy::Forbidden if library.nil?
    raise BlackCandy::Forbidden unless grant.library_id == library.id

    grant
  end

  # The set of libraries a user is authorized to browse: the Local_Libraries the
  # user owns plus the Remote_Libraries reached through an active
  # Library_Connection (Req 3.4). Library_Connections and remote libraries land
  # in Phase 2, so the remote half is guarded and contributes nothing until the
  # `library_connections` table exists — today this returns just the owned local
  # libraries. Returns an empty relation for a nil user so a user with access to
  # zero libraries browses nothing (Req 3.7).
  def authorized_libraries(user)
    return Library.none if user.nil?

    Library.where(id: user.authorized_library_ids)
  end

  # Raise `BlackCandy::Forbidden` unless the user is authorized to access the
  # given library, returning none of that library's content to the caller
  # (Req 3.3, 3.6).
  def authorize_library!(user, library)
    raise BlackCandy::Forbidden unless library && authorized_libraries(user).exists?(id: library.id)
  end

  # Authorize a user's attempt to select `library` as their Active_Library.
  #
  # When the selection is authorized the library is returned so the caller can
  # persist it. When it is not authorized the rejected attempt is logged
  # (Req 3.9) and `BlackCandy::Forbidden` is raised (Req 3.6); because this
  # raises before the caller writes `active_library_id`, the user's current
  # Active_Library is left unchanged.
  def authorize_active_library(user, library)
    return library if library && authorized_libraries(user).exists?(id: library.id)

    log_rejected_active_library_selection(user, library)
    raise BlackCandy::Forbidden
  end

  # Record a rejected Active_Library selection attempt in the server logs so the
  # rejection is auditable (Req 3.9).
  def log_rejected_active_library_selection(user, library)
    Rails.logger.warn(
      "Rejected Active_Library selection: user_id=#{user&.id} " \
      "library_id=#{library&.id} reason=unauthorized"
    )
  end
end
