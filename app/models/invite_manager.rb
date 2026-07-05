# frozen_string_literal: true

require "base64"
require "json"
require "securerandom"

# InviteManager encodes and decodes Invite_Codes.
#
# An Invite_Code is an opaque single string that carries the issuing Server's
# base URL and a secret access token. The encoding is a Base64URL (unpadded)
# representation of a compact JSON object `{u: base_url, t: token}`. Decoding
# reverses the process and raises InviteManager::Malformed on any input that is
# not a well-formed Invite_Code.
#
# Only encode/decode live here (Req 4.3, 4.7, 5.3). Generation, redemption, and
# revocation are implemented in separate tasks.
module InviteManager
  # Raised when an Invite_Code cannot be decoded into a Server base URL and a
  # secret token (Req 5.3).
  class Malformed < StandardError; end

  # Raised when an invite is requested for a Library that does not exist as a
  # local Library on the current Server (Req 4.9).
  class LibraryNotFound < StandardError; end

  # Raised when the requested expiration duration falls outside the allowed
  # range of 1 minute to 365 days inclusive (Req 4.5, 4.8).
  class InvalidExpiration < StandardError; end

  # Raised when a first-time redemption is attempted against an Invite_Code
  # whose expiration timestamp is already in the past (Req 5.4). An idempotent
  # re-redemption by the same User of a non-revoked grant does not raise this,
  # even after expiry (Req 5.6).
  class Expired < StandardError; end

  # Raised when redemption is rejected for an authorization reason: the local
  # Access_Grant has been revoked or does not match the presented token
  # (Req 5.5), or the issuing Server reports the grant is invalid or revoked on
  # the cross-server path (Req 5.8).
  class Revoked < StandardError; end

  # Raised when a cross-server redemption cannot reach the issuing Server or the
  # issuing Server does not respond within the 30 second confirmation budget
  # (Req 5.7). No Library_Connection is created in this case.
  class ServerUnavailable < StandardError; end

  # Raised when a revocation targets an Access_Grant that does not exist for a
  # Local_Library the requesting owner owns (Req 7.8).
  class GrantNotFound < StandardError; end

  # The outcome of a successful redemption (Req 5.1, 5.2, 5.6, 5.9).
  #
  # For a local redemption `library` and `access_grant` are populated and
  # `connection` is nil. For a cross-server redemption `connection` is populated
  # (holding the reused or freshly created Library_Connection) and `library` and
  # `access_grant` are nil because the shared Library lives on the hosting
  # Server. `success?` is always true — failures are surfaced as raised errors.
  RedemptionResult = Struct.new(:library, :access_grant, :connection, keyword_init: true) do
    def success?
      true
    end
  end

  # The number of bytes of cryptographic randomness in a generated secret
  # token. 16 bytes = 128 bits (Req 4.2).
  SECRET_TOKEN_BYTES = 16

  # Inclusive bounds for a requested invite expiration duration (Req 4.5, 4.8).
  MIN_EXPIRES_IN = 1.minute
  MAX_EXPIRES_IN = 365.days

  module_function

  # Encode the issuing Server base URL and secret token into one opaque string.
  #
  # @param server_base_url [String] the issuing Server's public base URL
  # @param secret_token [String] the secret access token
  # @return [String] a Base64URL (unpadded) encoded Invite_Code
  def encode(server_base_url:, secret_token:)
    payload = { u: server_base_url, t: secret_token }
    Base64.urlsafe_encode64(JSON.generate(payload), padding: false)
  end

  # Decode an Invite_Code back into its Server base URL and secret token.
  #
  # @param invite_code [String] the Invite_Code to decode
  # @return [Hash] `{server_base_url:, secret_token:}`
  # @raise [InviteManager::Malformed] when the input is not a valid Invite_Code
  def decode(invite_code)
    raise Malformed, "invite code is blank" if invite_code.nil? || invite_code.to_s.strip.empty?

    json = Base64.urlsafe_decode64(invite_code)
    payload = JSON.parse(json)

    raise Malformed, "invite code payload is not an object" unless payload.is_a?(Hash)

    server_base_url = payload["u"]
    secret_token = payload["t"]

    unless server_base_url.is_a?(String) && secret_token.is_a?(String)
      raise Malformed, "invite code is missing required fields"
    end

    { server_base_url: server_base_url, secret_token: secret_token }
  rescue ArgumentError, JSON::ParserError, Encoding::UndefinedConversionError => e
    raise Malformed, "invite code could not be decoded: #{e.message}"
  end

  # Generate an invite for a single local Library.
  #
  # Validates, in order and before any persistence, that the Library exists as a
  # local Library on the current Server (Req 4.9), that `owner` owns that Library
  # (Req 4.6), and that `expires_in` is between 1 minute and 365 days inclusive
  # (Req 4.5, 4.8). When every check passes it mints a 128-bit secret token
  # (Req 4.2), creates an Access_Grant recording the hashed token and an
  # expiration of `Time.current + expires_in` (defaulting to 7 days — Req 4.4),
  # and returns the encoded Invite_Code carrying this Server's base URL and the
  # secret token (Req 4.1, 4.3). Any validation failure raises without creating
  # an Access_Grant (Req 4.6, 4.8, 4.9).
  #
  # @param library [Library] the local Library to share
  # @param owner [User] the User requesting the invite, who must own the Library
  # @param expires_in [ActiveSupport::Duration] time until expiration (default 7 days)
  # @return [String] the encoded Invite_Code
  # @raise [InviteManager::LibraryNotFound] when the Library is not a local Library on this Server
  # @raise [BlackCandy::Forbidden] when `owner` does not own the Library
  # @raise [InviteManager::InvalidExpiration] when `expires_in` is out of range
  def generate(library:, owner:, expires_in: 7.days)
    raise LibraryNotFound, "library was not found on this server" unless local_library?(library)
    raise BlackCandy::Forbidden unless owns_library?(owner, library)
    raise InvalidExpiration, "expiration duration is out of the allowed range" unless valid_expires_in?(expires_in)

    secret_token = SecureRandom.hex(SECRET_TOKEN_BYTES)

    grant = AccessGrant.new(library: library, expires_at: Time.current + expires_in, status: :active)
    grant.token = secret_token
    grant.save!

    encode(server_base_url: current_server_base_url, secret_token: secret_token)
  end

  # This Server's effective public base URL: the runtime Setting when
  # configured, otherwise the SERVER_BASE_URL env config. Used everywhere an
  # Invite_Code is minted or matched so encoding and local/remote routing always
  # agree on this Server's identity.
  def current_server_base_url
    Setting.server_base_url
  end

  # A Library qualifies only when it is a persisted, local Library that still
  # exists on the current Server (Req 4.9).
  def local_library?(library)
    library.is_a?(Library) && library.persisted? && Library.local.exists?(id: library.id)
  end

  # Ownership requires a present owner whose id matches the Library's owner
  # (Req 4.6).
  def owns_library?(owner, library)
    owner.present? && library.owner_id.present? && library.owner_id == owner.id
  end

  # The requested duration must be a comparable duration within the inclusive
  # 1 minute–365 days range (Req 4.5, 4.8).
  def valid_expires_in?(expires_in)
    return false unless expires_in.respond_to?(:>=) && expires_in.respond_to?(:<=)

    expires_in >= MIN_EXPIRES_IN && expires_in <= MAX_EXPIRES_IN
  rescue ArgumentError, TypeError
    false
  end

  # Redeem an Invite_Code for `user` (Req 5.*).
  #
  # Decoding raises InviteManager::Malformed on any input that is not a
  # well-formed Invite_Code, leaving the User's existing access unchanged
  # (Req 5.3). The decoded issuing Server base URL is compared against this
  # Server's base URL to route the redemption down the local or the cross-server
  # path.
  #
  # Local path (the code references a Library on this Server):
  #   - a revoked or unknown Access_Grant is rejected with an authorization
  #     error (Req 5.5);
  #   - a re-redemption by the same User of a non-revoked grant reports success
  #     without recording a duplicate redemption, even if the code has since
  #     expired (Req 5.6);
  #   - a first-time redemption of an expired code is rejected (Req 5.4);
  #   - otherwise access is granted and the redemption is recorded against the
  #     grant (Req 5.1).
  #
  # Cross-server path (the code references a Library on another Server):
  #   - the issuing Server is asked to confirm the grant within 30 seconds; an
  #     unreachable or slow Server is rejected as unavailable with no
  #     Library_Connection created (Req 5.7);
  #   - a grant the issuing Server reports invalid or revoked is rejected with
  #     an authorization error and no Library_Connection (Req 5.8);
  #   - on confirmation a single Library_Connection is created, reusing any
  #     existing connection for the same User/Server/remote Library so no
  #     duplicate is created (Req 5.2, 5.9).
  #
  # @param invite_code [String] the Invite_Code to redeem
  # @param user [User] the redeeming User
  # @return [RedemptionResult] the successful redemption outcome
  # @raise [InviteManager::Malformed] when the code cannot be decoded (Req 5.3)
  # @raise [InviteManager::Revoked] on a revoked/invalid grant (Req 5.5, 5.8)
  # @raise [InviteManager::Expired] on a first-time expired redemption (Req 5.4)
  # @raise [InviteManager::ServerUnavailable] when the issuing Server is
  #   unreachable or times out (Req 5.7)
  def redeem(invite_code:, user:)
    decoded = decode(invite_code)

    if local_server?(decoded[:server_base_url])
      redeem_local(secret_token: decoded[:secret_token], user: user)
    else
      redeem_remote(server_base_url: decoded[:server_base_url], secret_token: decoded[:secret_token], user: user)
    end
  end

  # Grant access to a Library hosted on this Server (Req 5.1, 5.4, 5.5, 5.6).
  def redeem_local(secret_token:, user:)
    grant = AccessGrant.find_by_token(secret_token)

    # A missing grant means the token matches no Access_Grant on this Server;
    # like a revoked grant it is an authorization failure (Req 5.5).
    raise Revoked, "the access grant has been revoked" if grant.nil? || grant.revoked?

    # Idempotent re-redemption by the same User of a non-revoked grant reports
    # success with no change, even once the code has expired (Req 5.6).
    if redeemed_by?(grant, user)
      return RedemptionResult.new(library: grant.library, access_grant: grant, connection: nil)
    end

    # A first-time redemption of an expired code is rejected (Req 5.4).
    raise Expired, "the invite code has expired" if grant.expired?

    # Grant access and record the redemption against the grant (Req 5.1).
    grant.update!(redeemer_user: user, redeemed_at: Time.current)

    RedemptionResult.new(library: grant.library, access_grant: grant, connection: nil)
  end

  # Establish (or reuse) a Library_Connection to a Library on another Server
  # (Req 5.2, 5.7, 5.8, 5.9).
  def redeem_remote(server_base_url:, secret_token:, user:)
    client = Federation::Client.new(base_url: server_base_url, grant_token: secret_token)

    # Generate the redeemer's best-effort Catalog_Nudge registration up front so
    # it can be passed through confirmation (registering the callback on the
    # host, Req 6.1) and stored on the resulting Library_Connection (Req 6.5).
    # The callback targets this redeeming Server's own Nudge_Endpoint, derived
    # from its configured base URL + "/nudges" (the same base URL mechanism used
    # to encode Invite_Codes).
    nudge_token = SecureRandom.hex(SECRET_TOKEN_BYTES)
    nudge_callback_url = nudge_callback_url_for(current_server_base_url)

    begin
      confirmation = client.confirm_grant(
        nil,
        nudge_callback_url: nudge_callback_url,
        nudge_token: nudge_token
      )
    rescue Federation::Client::Unauthorized => e
      # The issuing Server reports the grant is invalid or revoked (Req 5.8).
      raise Revoked, "the issuing server rejected the access grant: #{e.message}"
    rescue Federation::Client::Unreachable, Federation::Client::Timeout => e
      # The issuing Server is unreachable or did not respond in time (Req 5.7).
      raise ServerUnavailable, "the issuing server is unavailable: #{e.message}"
    rescue Federation::Client::Error => e
      # Any other federation failure is treated as the issuing Server being
      # unable to confirm the grant; no Library_Connection is created (Req 5.7).
      raise ServerUnavailable, "the issuing server could not confirm the grant: #{e.message}"
    end

    unless confirmation.is_a?(Hash) && confirmation["valid"]
      raise Revoked, "the issuing server did not confirm the access grant"
    end

    remote_library_id = confirmation.dig("library", "id")

    connection = find_or_create_connection(
      user: user,
      server_base_url: server_base_url,
      remote_library_id: remote_library_id,
      grant_token: secret_token,
      nudge_token: nudge_token
    )

    RedemptionResult.new(library: nil, access_grant: nil, connection: connection)
  end

  # The redeeming Server's own Nudge_Endpoint URL: its configured base URL with
  # a "/nudges" suffix (Req 6.1). Normalizes the base URL so a trailing slash
  # never produces a doubled separator.
  def nudge_callback_url_for(base_url)
    "#{normalize_url(base_url)}/nudges"
  end

  # Whether `user` has already recorded a redemption against `grant` (Req 5.6).
  def redeemed_by?(grant, user)
    user.present? && grant.redeemer_user_id == user.id && grant.redeemed_at.present?
  end

  # The code references this Server when its decoded base URL matches this
  # Server's configured base URL (Req 5.1 vs 5.2 routing).
  def local_server?(server_base_url)
    normalize_url(server_base_url) == normalize_url(current_server_base_url)
  end

  def normalize_url(url)
    url.to_s.strip.chomp("/")
  end

  # Reuse an existing Library_Connection for this User/Server/remote Library or
  # create a single new one, so re-redemption never creates a duplicate
  # (Req 5.9, enforced by the unique index on
  # [user_id, server_base_url, remote_library_id]).
  def find_or_create_connection(user:, server_base_url:, remote_library_id:, grant_token:, nudge_token: nil)
    attributes = { user: user, server_base_url: server_base_url, remote_library_id: remote_library_id }

    connection = LibraryConnection.create_or_find_by!(attributes) do |new_connection|
      new_connection.grant_token = grant_token
      new_connection.status = :active
      # The per-connection nudge token the redeemer registered with the host, so
      # a received nudge maps back to this connection (Req 6.5). Set only on
      # creation; a reused connection keeps its existing token.
      new_connection.nudge_token = nudge_token
    end

    # Only a brand-new Library_Connection materializes the mirror; an existing
    # connection reused by an idempotent re-redemption must not re-trigger a
    # full sync (Req 1.1). create_or_find_by! marks a freshly inserted row via
    # previously_new_record?, distinguishing creation from find-and-reuse.
    if connection.previously_new_record?
      CatalogSyncJob.perform_later(connection.id, mode: :full)
    end

    connection
  end

  # List every Access_Grant for a local Library so its owner can review who has
  # access (Req 7.1). Ownership is verified first: a User who does not own the
  # Library is rejected with an authorization error and sees none of its grants
  # (Req 7.5). Each returned grant carries its redemption status (`status`,
  # `redeemed_at`) and its `expires_at`. When the Library has no grants the
  # result is an empty collection rather than an error (Req 7.1).
  #
  # @param library [Library] the local Library whose grants to list
  # @param owner [User] the User requesting the list, who must own the Library
  # @return [ActiveRecord::Relation<AccessGrant>] the Library's grants (possibly empty)
  # @raise [BlackCandy::Forbidden] when `owner` does not own the Library
  def access_list(library:, owner:)
    raise BlackCandy::Forbidden unless owns_library?(owner, library)

    AccessGrant.where(library_id: library.id).order(:id)
  end

  # Revoke a single Access_Grant on behalf of its Library's owner (Req 7.2).
  #
  # Ordering of the checks matters. A nil grant references nothing to revoke and
  # is reported as not-found (Req 7.8). The requesting `owner` must own the
  # grant's Library, otherwise the request is rejected with an authorization
  # error and the grant is left unchanged (Req 7.5). When both checks pass the
  # grant's status is set to revoked and the grant is returned as confirmation
  # (Req 7.2). Revoking a grant that is already revoked leaves it revoked and
  # reports success without further change (Req 7.7). Every other Access_Grant
  # for the same Library is left untouched because only the identified grant is
  # updated (Req 7.6, 7.9).
  #
  # @param access_grant [AccessGrant, nil] the grant to revoke
  # @param owner [User] the User requesting revocation, who must own the Library
  # @return [AccessGrant] the revoked grant
  # @raise [InviteManager::GrantNotFound] when `access_grant` is nil (Req 7.8)
  # @raise [BlackCandy::Forbidden] when `owner` does not own the grant's Library (Req 7.5)
  def revoke(access_grant:, owner:)
    raise GrantNotFound, "the access grant was not found" if access_grant.nil?
    raise BlackCandy::Forbidden unless owns_library?(owner, access_grant.library)

    # Idempotent: an already-revoked grant is left revoked and reported as a
    # successful revocation without a further write (Req 7.7).
    return access_grant if access_grant.revoked?

    access_grant.update!(status: :revoked)
    access_grant
  end
end
