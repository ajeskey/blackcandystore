# frozen_string_literal: true

module Federation
  # Confirms at redemption time that a presented grant token is valid and
  # references a given local library on this hosting Server (Req 5.2). The
  # redeeming Server calls this before creating a Library_Connection.
  #
  # Responds `200 { library: { id, name }, valid: true }` when the grant is
  # valid, or 403 (rendered by ExceptionRescue) when it is not.
  class GrantsController < BaseController
    def confirm
      authorize_federation!(params[:library_id])

      register_nudge_callback

      render json: {
        library: { id: @library.id, name: @library.name },
        valid: true
      }
    end

    private

    # Persist the redeemer's best-effort Catalog_Nudge registration on the
    # matched Access_Grant (memoized as @access_grant by authorize_federation!)
    # so the host can later POST a nudge when the shared library changes
    # (Req 6.1). Both fields are optional; the update is best-effort and only
    # runs when a callback URL is supplied, leaving grants without a callback
    # untouched.
    def register_nudge_callback
      callback_url = params[:nudge_callback_url]
      return if @access_grant.nil? || callback_url.blank?

      @access_grant.update(
        nudge_callback_url: callback_url,
        nudge_token: params[:nudge_token]
      )
    end
  end
end
