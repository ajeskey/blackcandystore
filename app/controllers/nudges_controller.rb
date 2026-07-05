# frozen_string_literal: true

# Redeeming-side Nudge_Endpoint (Req 6.2, 6.5).
#
# A hosting Server that just bumped its Catalog_Version POSTs a best-effort
# Catalog_Nudge here so the redeeming Server can pull sooner than its next
# scheduled Incremental_Sync. This is purely an optimization on top of the
# converging pull backbone: whether or not a nudge ever arrives, the scheduled
# pull still converges the mirror (Req 6.4).
#
# Like the federation endpoints, this is a token-authenticated server-to-server
# call, not a browser/app request. It therefore does NOT use the app's normal
# cookie/session authentication or CSRF protection. It inherits from
# ActionController::API (rather than ApplicationController), which includes
# neither the Authentication concern nor RequestForgeryProtection, so there is
# no session login requirement to skip and no CSRF token to verify.
#
# The `nudge_token` itself is the only credential: it is looked up against the
# redeemer's own LibraryConnection rows. An unknown or inactive token is ignored
# and still returns 204, so the endpoint never discloses whether a connection
# exists for a given token (Req 6.5).
class NudgesController < ActionController::API
  # POST /nudges { nudge_token }
  #
  # Enqueues an immediate Incremental_Sync for the matching, active connection;
  # ignores unknown/inactive tokens. Always returns 204 No Content.
  def create
    connection = LibraryConnection.find_by(nudge_token: params[:nudge_token])
    CatalogSyncJob.perform_later(connection.id, mode: :incremental) if connection&.active?
    head :no_content
  end
end
