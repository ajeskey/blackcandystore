# frozen_string_literal: true

# Mints an Invite_Code scoped to a single local Library on behalf of that
# Library's owner (Req 4.1, 4.6).
#
# The endpoint is owner-only, but the ownership check lives in
# `InviteManager.generate`, which raises `BlackCandy::Forbidden` when the
# requesting User does not own the named Library (Req 4.6). That keeps the
# authorization decision in one place and ensures a non-owner request never
# creates an Access_Grant. Domain failures (a missing/non-local library, an
# out-of-range expiration) are raised by the manager and rendered by
# ExceptionRescue.
class InvitesController < ApplicationController
  # Create an invite for the Library identified by `library_id`.
  #
  # Accepts an optional `expires_in` (a duration in seconds); when omitted the
  # manager applies its 7-day default (Req 4.4). On success the encoded
  # Invite_Code is returned (Req 4.1, 4.3).
  def create
    library = Library.find(params[:library_id])
    invite_code = InviteManager.generate(**generate_options(library))

    respond_to do |format|
      format.json { render json: { invite_code: invite_code }, status: :created }
      format.html { redirect_back_or_to libraries_path, notice: t("notice.created") }
    end
  end

  private

  # Builds the keyword arguments for `InviteManager.generate`. `expires_in` is
  # forwarded only when the caller supplied it, so an omitted value falls back
  # to the manager's 7-day default (Req 4.4); a supplied value is interpreted as
  # a number of seconds and validated against the allowed range by the manager
  # (Req 4.5, 4.8).
  def generate_options(library)
    options = { library: library, owner: Current.user }
    options[:expires_in] = params[:expires_in].to_i.seconds if params[:expires_in].present?
    options
  end
end
