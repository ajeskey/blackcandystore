# frozen_string_literal: true

# Reads and updates the current User's Source_Preference (Req 11.3, 11.10).
#
# On update, a supported value (`prefer_own_server` / `prefer_highest_quality`)
# is persisted and applies to subsequent source resolution for that User
# (Req 11.3). Any other value is rejected: the User model's inclusion
# validation raises ActiveRecord::RecordInvalid, which ExceptionRescue surfaces
# as a validation error (422 for JSON clients, a flash alert for browsers), and
# because the save fails the User's existing Source_Preference is left
# unchanged (Req 11.10).
class SourcePreferencesController < ApplicationController
  def show
    render json: { source_preference: Current.user.source_preference }
  end

  def update
    Current.user.update!(source_preference_params)

    respond_to do |format|
      format.json { render json: { source_preference: Current.user.source_preference } }
      format.html { redirect_back_or_to root_path, notice: t("notice.updated") }
    end
  end

  private

  def source_preference_params
    params.permit(:source_preference)
  end
end
