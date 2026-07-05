# frozen_string_literal: true

# Redeems an Invite_Code for the current User (Req 5.1, 5.3).
#
# Delegates entirely to `InviteManager.redeem`, which routes the code down the
# local or cross-server path and raises the appropriate domain error on
# failure: `Malformed` for an undecodable code (Req 5.3), `Expired` /`Revoked`
# for an unusable grant (Req 5.4, 5.5), and `ServerUnavailable` when the issuing
# Server cannot confirm a cross-server grant (Req 5.7). All of these are
# rendered by ExceptionRescue. On success the resolved Library (local
# redemption) or Library_Connection (cross-server redemption) is returned.
class RedemptionsController < ApplicationController
  # Render the form for redeeming an invite code.
  def new
  end

  def create
    result = InviteManager.redeem(invite_code: params[:invite_code], user: Current.user)

    respond_to do |format|
      format.json { render json: redemption_json(result), status: :created }
      format.html { redirect_back_or_to library_overview_path, notice: t("notice.created") }
    end
  end

  private

  # Serializes a successful redemption. A local redemption carries the shared
  # Library; a cross-server redemption carries the Library_Connection that
  # reaches the Remote_Library on the hosting Server (Req 5.1, 5.2).
  def redemption_json(result)
    if result.connection.present?
      {
        connection: {
          id: result.connection.id,
          server_base_url: result.connection.server_base_url,
          remote_library_id: result.connection.remote_library_id,
          status: result.connection.status
        }
      }
    else
      {
        library: {
          id: result.library.id,
          name: result.library.name
        }
      }
    end
  end
end
