# frozen_string_literal: true

# Access_Grant lives on the hosting server. It authorizes a specific redeemer
# to access a specific local Library and can be revoked (Req 4.1, 7.2).
#
# The secret token is never stored in plaintext: only its keyed digest is
# persisted in `token_digest`. Federation requests present the plaintext token
# as a Bearer credential; the hosting server digests the presented token and
# compares it against stored digests with a constant-time comparison so token
# lookup does not leak timing information (design: credential / auth model).
class AccessGrant < ApplicationRecord
  belongs_to :library

  # Set on local redemption (Req 5.1); nullable for cross-server redeemers whose
  # identity is recorded opaquely in `redeemer_identity` instead.
  belongs_to :redeemer_user, class_name: "User", optional: true

  # Status transitions from active to revoked; revocation is terminal (Req 7.2).
  # The enum generates the `active`/`revoked` scopes and predicates used by the
  # Library_Access_Controller and Invite_Manager.
  enum :status, { active: "active", revoked: "revoked" }, default: :active

  validates :token_digest, presence: true

  # Assigns the plaintext secret token, storing only its keyed digest. The
  # plaintext is kept in-memory (via `token`) so a freshly generated grant can
  # be encoded into an Invite_Code exactly once, but it is never persisted.
  def token=(raw_token)
    @token = raw_token
    self.token_digest = raw_token.present? ? self.class.digest(raw_token) : nil
  end

  # The plaintext token, available only on the in-memory instance that set it
  # (e.g. right after generation). Reloaded records return nil.
  attr_reader :token

  # Constant-time verification of a presented plaintext token against this
  # grant's stored digest. Returns false rather than raising on blank input.
  def authenticate_token(raw_token)
    return false if raw_token.blank? || token_digest.blank?

    self.class.secure_compare(token_digest, self.class.digest(raw_token))
  end

  # A grant is expired once its expiration timestamp is in the past. A nil
  # `expires_at` means the grant never expires.
  def expired?
    expires_at.present? && expires_at.past?
  end

  # A grant may authorize content only while it is active and not expired
  # (Req 6.5). Revoked or expired grants are unusable.
  def usable?
    active? && !expired?
  end

  # Keyed digest of a plaintext token. HMAC-SHA256 keyed on the application's
  # secret_key_base yields a deterministic, unique digest suitable for the
  # `token_digest` unique index while never exposing the plaintext at rest.
  def self.digest(raw_token)
    OpenSSL::HMAC.hexdigest("SHA256", digest_key, raw_token.to_s)
  end

  # Locates the grant whose stored digest matches the presented plaintext token,
  # confirming the match with a constant-time comparison. Returns nil when no
  # grant matches. Callers still enforce status/expiration (see `usable?`) as
  # defense-in-depth — a match alone is never sufficient (Req 6.6, 6.8).
  def self.find_by_token(raw_token)
    return if raw_token.blank?

    grant = find_by(token_digest: digest(raw_token))
    grant if grant&.authenticate_token(raw_token)
  end

  # Constant-time string comparison. `secure_compare` tolerates differing
  # lengths without leaking which bytes matched.
  def self.secure_compare(left, right)
    ActiveSupport::SecurityUtils.secure_compare(left.to_s, right.to_s)
  end

  def self.digest_key
    Rails.application.secret_key_base
  end
  private_class_method :digest_key
end
