# frozen_string_literal: true

# Manages the current User's Library_Connections to Remote_Libraries on other
# servers (Req 5.2, 9.3).
#
# A connection is created when the User redeems a cross-server Invite_Code
# (see RedemptionsController); this controller lets the User remove one again.
# Destroying the Library_Connection tears down its Catalog_Mirror in full
# through the model's `has_one :library, dependent: :destroy` cascade, which in
# turn removes every Mirrored_Song and the orphaned Mirrored_Albums/Artists
# scoped to that Library (Req 9.3). The lookup is scoped to `Current.user`, so a
# User can only disconnect their own connections; another User's connection id
# resolves to RecordNotFound and is rejected.
class LibraryConnectionsController < ApplicationController
  def destroy
    connection = Current.user.library_connections.find(params[:id])
    connection.destroy

    respond_to do |format|
      format.html { redirect_to libraries_path, notice: t("notice.deleted") }
      format.json { head :no_content }
    end
  end
end
