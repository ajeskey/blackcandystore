module ExceptionRescue
  extend ActiveSupport::Concern

  included do
    rescue_from BlackCandy::Forbidden do |error|
      respond_to do |format|
        format.json { render_json_error(error.type, error.message, :forbidden) }
        format.html { render template: "errors/forbidden", layout: "plain", status: :forbidden }
      end
    end

    rescue_from BlackCandy::InvalidCredential do |error|
      respond_to do |format|
        format.json { render_json_error(error.type, error.message, :unauthorized) }
        format.html { redirect_to new_session_path, alert: t("error.login") }
      end
    end

    rescue_from BlackCandy::DuplicatePlaylistSong do |error|
      respond_to do |format|
        format.json { render_json_error(error.type, error.message, :bad_request) }
        format.html { redirect_back_or_to root_path, alert: t("error.already_in_playlist") }
        format.turbo_stream { render turbo_stream: stream_flash(type: :alert, message: t("error.already_in_playlist")) }
      end
    end

    rescue_from BlackCandy::Unauthorized do |error|
      respond_to do |format|
        format.json { render_json_error(error.type, error.message, :unauthorized) }
        format.html { redirect_to new_session_path }
      end
    end

    rescue_from ActiveRecord::RecordNotFound do |error|
      respond_to do |format|
        format.json { render_json_error("RecordNotFound", error.message, :not_found) }
        format.html { render template: "errors/not_found", layout: "plain", status: :not_found }
      end
    end

    rescue_from ActiveRecord::RecordInvalid do |error|
      errors_message = error.record.errors.full_messages.join(". ")

      respond_to do |format|
        format.json { render_json_error("RecordInvalid", errors_message, :unprocessable_entity) }
        format.html { redirect_back_or_to root_path, alert: errors_message }
      end
    end

    # Invite_Manager domain errors (Req 4, 5, 7). Unlike BlackCandy::BaseError
    # these are plain StandardError subclasses, so they are surfaced here with a
    # consistent JSON body (`{ type:, message: }`) and an HTML error page, using
    # the status that best matches each failure:
    #
    #   Malformed / InvalidExpiration -> 422 (the submitted input is invalid)
    #   Expired / Revoked             -> 403 (access is denied)
    #   ServerUnavailable             -> 503 (the issuing server is unreachable)
    #   LibraryNotFound / GrantNotFound -> 404 (the referenced record is absent)
    rescue_from InviteManager::Malformed do |error|
      render_domain_error(error, :unprocessable_entity, "errors/unprocessable_entity")
    end

    rescue_from InviteManager::InvalidExpiration do |error|
      render_domain_error(error, :unprocessable_entity, "errors/unprocessable_entity")
    end

    rescue_from InviteManager::Expired do |error|
      render_domain_error(error, :forbidden, "errors/forbidden")
    end

    rescue_from InviteManager::Revoked do |error|
      render_domain_error(error, :forbidden, "errors/forbidden")
    end

    rescue_from InviteManager::ServerUnavailable do |error|
      render_domain_error(error, :service_unavailable, "errors/internal_server_error")
    end

    rescue_from InviteManager::LibraryNotFound do |error|
      render_domain_error(error, :not_found, "errors/not_found")
    end

    rescue_from InviteManager::GrantNotFound do |error|
      render_domain_error(error, :not_found, "errors/not_found")
    end
  end

  private

  def render_json_error(type, message, status)
    render json: { type: type, message: message }, status: status
  end

  # Renders an Invite_Manager domain error consistently across formats: a JSON
  # error body for API clients and the matching plain-layout HTML error page for
  # browsers. The `type` mirrors the BlackCandy::BaseError#type convention (the
  # unqualified class name, e.g. "Malformed").
  def render_domain_error(error, status, html_template)
    type = error.class.name.split("::").last

    respond_to do |format|
      format.json { render_json_error(type, error.message, status) }
      format.html { render template: html_template, layout: "plain", status: status }
    end
  end
end
