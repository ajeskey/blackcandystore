# frozen_string_literal: true

module Federation
  # Base controller for the hosting side of the cross-server (federation) API.
  #
  # These endpoints are called by a remote redeeming Server, not by a browser or
  # the native apps, so they do NOT use the app's normal cookie/session
  # authentication. Instead every request presents an Access_Grant secret token
  # as `Authorization: Bearer <token>` (see the design's Cross-Server HTTP API
  # Contract). We therefore skip the login requirement and CSRF protection and
  # authorize each request against a matching, active, non-revoked Access_Grant
  # via `authorize_grant!` from the LibraryAccess concern.
  #
  # Only local, authorized content is ever served: `authorized_library!` loads
  # the library through `Library.local`, and every content query is scoped to
  # that library's id.
  class BaseController < ApplicationController
    include LibraryAccess

    # Federation requests are token-authenticated (Bearer grant token), so the
    # app's session-based login requirement does not apply here (Req 6.4).
    skip_before_action :require_login

    # Token-authenticated JSON API called server-to-server; there is no browser
    # session/cookie to protect against, so CSRF verification is not applicable.
    skip_forgery_protection

    private

    # Authorize the presented Bearer token against the library named in the
    # request and return the matching Access_Grant. Raises BlackCandy::Forbidden
    # (rendered as 403 by ExceptionRescue) on any authorization failure. The
    # authorized local library is memoized in `@library` so actions serve only
    # that library's content (Req 6.4, 6.5, 6.6, 6.8).
    def authorize_federation!(library_id)
      @access_grant = authorize_grant!(presented_token, library_id)
      @library = Library.local.find_by(id: library_id)

      # Defense-in-depth: the referenced library must still exist and be local.
      # A credential match alone is never sufficient (Req 6.8).
      raise BlackCandy::Forbidden if @library.nil?

      @access_grant
    end

    # The plaintext grant token presented on the request. Supports both the
    # `Bearer <token>` and `Token <token>` Authorization schemes.
    def presented_token
      token = authenticate_with_http_token { |value, _options| value }
      return token if token.present?

      request.authorization.to_s.sub(/\ABearer\s+/i, "").presence
    end

    # Temporary fallback for `authorize_grant!`.
    #
    # The canonical implementation lands in the LibraryAccess concern (task
    # 11.3). This fallback is defined ONLY when that concern does not yet provide
    # the method, so the federation endpoints are functional and testable in the
    # meantime and so there is no conflict once the concern's version exists.
    unless LibraryAccess.method_defined?(:authorize_grant!) ||
        LibraryAccess.private_method_defined?(:authorize_grant!)
      def authorize_grant!(token, library_id)
        grant = AccessGrant.find_by_token(token)

        # No matching grant → reject regardless of anything else (Req 6.6).
        raise BlackCandy::Forbidden if grant.nil?

        # Revoked or expired grants are unusable (Req 6.5, 7.3, 7.4).
        raise BlackCandy::Forbidden unless grant.usable?

        # The grant must reference the requested library (Req 6.8).
        raise BlackCandy::Forbidden unless grant.library_id.to_s == library_id.to_s

        grant
      end

      private :authorize_grant!
    end
  end
end
