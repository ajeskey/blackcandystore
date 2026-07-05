# frozen_string_literal: true

module Federation
  # Serves the Changes_Since_API to a remote redeeming Server: the ordered
  # Catalog_Changes for a local library that occurred after the presented
  # Sync_Cursor, together with the Catalog_Version to adopt (Req 3.2).
  #
  # Authorization reuses the base controller's `authorize_federation!`, which
  # digests the presented Bearer token, requires a matching Access_Grant that is
  # `usable?` (active and not expired) and references the requested library, and
  # returns 403 otherwise (Req 3.3). No change is returned until authorization
  # passes; a 403 here is the redeemer's teardown signal.
  #
  # The change page is computed by `CatalogChange.changes_since`, which handles
  # the empty-at-or-beyond-current-version case (Req 3.6) and the
  # full-sync-required-below-the-retained-floor case (Req 3.7). Each upsert is
  # rendered through the same jbuilder shapes local browsing produces, so the
  # mirror receives the identical field set (metadata + associations, Req 3.4).
  class ChangesController < BaseController
    def index
      authorize_federation!(params[:library_id])

      @result = CatalogChange.changes_since(@library, params[:cursor], params[:page] || 1)

      # Expose the pagy object so the shared Pagination concern emits the same
      # pagination headers as the rest of the Federation API.
      @pagy = @result.pagy

      # `song_json_builder` consults `Current.user` only to resolve the per-user
      # favorite flag, which has no meaning for a cross-server request. Pre-set
      # it on each upserted song so rendering never touches the absent session
      # user (mirrors LibrariesController#songs).
      @result.changes.each do |change|
        change.record.is_favorited = false if change.item_type == "song" && change.record
      end

      render template: "federation/changes/index", formats: :json
    end
  end
end
