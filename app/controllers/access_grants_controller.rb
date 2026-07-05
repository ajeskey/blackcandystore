# frozen_string_literal: true

# Lets a Library owner review and revoke the Access_Grants for a local Library
# they own (Req 7.1, 7.2, 7.5, 7.8).
#
# Both authorization decisions live in the Invite_Manager: `access_list` and
# `revoke` verify ownership and raise `BlackCandy::Forbidden` for a non-owner
# (Req 7.5), and `revoke` raises `InviteManager::GrantNotFound` for a missing
# grant (Req 7.8). Those errors are rendered by ExceptionRescue, so the
# controller only resolves the records and serializes the result.
class AccessGrantsController < ApplicationController
  before_action :find_library, only: [ :index ]

  # List every Access_Grant for a local Library the current User owns, each with
  # its redemption status and expiration timestamp; an empty list when the
  # Library has no grants (Req 7.1). Ownership is enforced by `access_list`,
  # which rejects a non-owner with an authorization error (Req 7.5).
  def index
    @access_grants = InviteManager.access_list(library: @library, owner: Current.user)

    respond_to do |format|
      format.json { render json: { access_grants: @access_grants.map { |grant| grant_json(grant) } } }
    end
  end

  # Revoke a single Access_Grant on behalf of its Library's owner (Req 7.2).
  # `find_by` (not `find`) yields nil for a missing id so `revoke` can raise the
  # not-found domain error (Req 7.8) rather than the generic RecordNotFound.
  def destroy
    access_grant = AccessGrant.find_by(id: params[:id])
    revoked = InviteManager.revoke(access_grant: access_grant, owner: Current.user)

    respond_to do |format|
      format.json { render json: grant_json(revoked) }
      format.html { redirect_back_or_to libraries_path, notice: t("notice.updated") }
    end
  end

  private

  def find_library
    @library = Library.find(params[:library_id])
  end

  # Redemption status (`status`, `redeemed_at`) and expiration for a grant
  # (Req 7.1).
  def grant_json(grant)
    {
      id: grant.id,
      library_id: grant.library_id,
      status: grant.status,
      redeemer_user_id: grant.redeemer_user_id,
      redeemed_at: grant.redeemed_at,
      expires_at: grant.expires_at
    }
  end
end
