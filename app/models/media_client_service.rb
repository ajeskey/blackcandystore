# frozen_string_literal: true

# MediaClientService is the shared Rails-side boundary for exposing library
# content to external Media_Clients over legacy protocols — DAAP (iTunes) and
# RSP (Roku). Concrete protocols are the DAAPService and RSPService subclasses
# (Req 15).
#
# What this class owns (the Rails-testable parts, per the design's Notable
# Technical Risks note):
#
#   1. Enablement gating — each service is independently enabled/disabled via a
#      `Setting` flag (`enable_daap` / `enable_rsp`). When disabled the service
#      refuses connections and serves NO content (Req 15.3, 15.4, 15.5).
#   2. Authentication — a connecting Media_Client is authenticated as a User
#      account using the server's EXISTING authentication model (the same
#      email/password check used for web/API login, via Session). On failed
#      authentication the connection is refused with an authentication error and
#      NO content is served (Req 15.6, 15.7).
#   3. Authorized-content selection — a connected service serves ONLY local,
#      authorized content via `AuthorizedContent.for(user)`; it never serves
#      Remote_Library content (Req 15.8, 15.10; Property 22). Because the
#      authorized set is recomputed from the account's current libraries on each
#      call, revoking an account's authorization immediately stops serving that
#      content (Req 15.9).
#
# What this class deliberately does NOT own — the WIRE PROTOCOL:
#
#   DAAP and RSP are legacy binary/HTTP protocols with no maintained pure-Ruby
#   servers. The realistic implementation fronts or embeds an EXTERNAL media
#   server (e.g. an OwnTone/forked-daapd style daemon) behind Black Candy's auth
#   and this content selection. The actual protocol framing lives in that
#   external component and is exercised only by the integration/smoke tests in
#   task 29.2 — never by Ruby here. The `Adapter` seam below marks that boundary
#   explicitly and is intentionally thin/stubbed.
class MediaClientService
  # Raised when a Media_Client tries to connect while the service is disabled.
  # The connection is refused and no content is served (Req 15.4, 15.5).
  class Disabled < StandardError; end

  # Raised when a connecting Media_Client fails authentication against the
  # server's existing authentication model. The connection is refused and no
  # content is served (Req 15.7).
  class AuthenticationError < StandardError; end

  attr_reader :user

  # Bind the service to an already-authenticated User account. `connect`
  # guarantees a non-nil user; a nil user (or a disabled service) yields empty
  # served content defensively so instantiating directly can never leak content.
  def initialize(user)
    @user = user
  end

  class << self
    # Whether this service is currently enabled via its `Setting` flag
    # (Req 15.3). Subclasses supply the flag name through `enable_setting`.
    def enabled?
      Setting.public_send("#{enable_setting}?")
    end

    # Authenticate and connect a Media_Client in one step, returning a service
    # instance bound to the authenticated account.
    #
    # Refuses (raises) and serves nothing when the service is disabled
    # (Req 15.4, 15.5) or when authentication fails (Req 15.6, 15.7). Order
    # matters: a disabled service refuses before credentials are even considered.
    def connect(email:, password:)
      raise Disabled, "#{protocol} service is disabled" unless enabled?

      user = authenticate(email: email, password: password)
      raise AuthenticationError, "#{protocol} authentication failed" if user.nil?

      new(user)
    end

    # Authenticate a Media_Client's credentials against a User account using the
    # server's existing authentication model — the SAME `Session`-based
    # email/password check used for web and API login (Req 15.6). Returns the
    # authenticated User, or nil when the credentials do not match an account.
    def authenticate(email:, password:)
      Session.build_from_credential(email: email, password: password).user
    end

    # The human-readable protocol name, used in error messages.
    def protocol
      name.sub(/Service\z/, "")
    end

    # The `Setting` flag that enables/disables this service. Subclasses override.
    def enable_setting
      raise NotImplementedError, "#{name} must define .enable_setting"
    end
  end

  # Instance-level enablement check, delegating to the class gate so a bound
  # service reflects the live setting (Req 15.3).
  def enabled?
    self.class.enabled?
  end

  # The Songs this service serves — only local, authorized content (Req 15.8,
  # 15.10). Empty when the service is disabled or no account is bound.
  def songs
    authorized_content.songs
  end

  # The Albums this service serves — only local, authorized content.
  def albums
    authorized_content.albums
  end

  # The Artists this service serves — only local, authorized content.
  def artists
    authorized_content.artists
  end

  private

  # The authorized-content selection for the bound account. A disabled service
  # or an unbound (nil) user resolves to the empty set so no content is ever
  # served outside an enabled, authenticated connection (Req 15.4, 15.5, 15.7,
  # 15.8, 15.10).
  def authorized_content
    return AuthorizedContent.for(nil) unless enabled? && user

    AuthorizedContent.for(user)
  end

  # Adapter is the thin, clearly-delineated seam between this Rails boundary and
  # the EXTERNAL media server that speaks the actual DAAP/RSP wire protocol.
  #
  # STUBBED ON PURPOSE: a from-scratch binary protocol implementation is out of
  # scope for the Rails side (see the design's Notable Technical Risks). The real
  # adapter would hand the authenticated account and its authorized content set
  # to a fronted/embedded external daemon and translate that daemon's browse /
  # download-and-play traffic back through this authorization boundary. Wiring
  # and conformance against real iTunes/Roku clients is covered by the
  # integration/smoke tests in task 29.2, not here.
  class Adapter
    def initialize(service)
      @service = service
    end

    # Placeholder for handing the authorized content set to the external media
    # server. Intentionally not implemented on the Rails side.
    def serve
      raise NotImplementedError,
        "DAAP/RSP wire protocol is served by an external media server; " \
        "see task 29.2 integration/smoke tests"
    end
  end
end
