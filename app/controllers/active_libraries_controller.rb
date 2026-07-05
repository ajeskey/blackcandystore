# frozen_string_literal: true

# Selects which Library the current User is browsing — their Active_Library
# (Req 3.1). Available to any User, for any Library they are authorized to
# access (an owned Local_Library or a Remote_Library reached through an active
# Library_Connection).
#
# Authorization is delegated to `LibraryAccess#authorize_active_library`, which
# logs and raises `BlackCandy::Forbidden` when the User is not authorized to
# select the Library (Req 3.6, 3.9); because that raises before the selection is
# persisted, the User's current Active_Library is left unchanged.
class ActiveLibrariesController < ApplicationController
  include LibraryAccess

  def update
    library = Library.find(params[:library_id])
    authorize_active_library(Current.user, library)
    Current.user.update!(active_library: library)

    respond_to do |format|
      format.html { redirect_back_or_to library_overview_path, notice: t("notice.updated") }
      format.json { head :no_content }
    end
  end
end
