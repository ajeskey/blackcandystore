# frozen_string_literal: true

# A Stream_Token authorizes tuning into a Radio_Station's Shared_Stream when
# the station is not public. Because generic MP3 clients cannot present cookies
# or Authorization headers (Assumption A3), the token travels embedded in the
# Stream_Endpoint URL. It is rotatable and revocable (Req 11.5).
#
# Like AccessGrant, the secret is never stored in plaintext: only its keyed
# digest is persisted in `token_digest`. Presented tokens are digested and
# compared with a constant-time comparison so lookup does not leak timing
# information.
#
# Co-listen stream tokens are intentionally NOT modeled here; they are derived
# per-participant from the Guest_Token as purpose-scoped signed tokens so they
# invalidate automatically when guest access ends (Req 11.8, 11.9).
class StreamToken < ApplicationRecord
  belongs_to :radio_station

  # A token transitions from active to revoked; revocation is terminal. The
  # enum generates the `active`/`revoked` scopes and predicates.
  enum :status, { active: "active", revoked: "revoked" }, default: :active

  validates :token_digest, presence: true

  # Assigns the plaintext Stream_Token, storing only its keyed digest. The
  # plaintext is retained in-memory (via `token`) so a freshly generated or
  # rotated token can be embedded into the Stream_Endpoint URL once; it is
  # never persisted.
  def token=(raw_token)
    @token = raw_token
    self.token_digest = raw_token.present? ? self.class.digest(raw_token) : nil
  end

  # The plaintext token, available only on the in-memory instance that set it.
  # Reloaded records return nil.
  attr_reader :token

  # Constant-time verification of a presented plaintext token against this
  # token's stored digest. Returns false rather than raising on blank input.
  def authenticate_token(raw_token)
    return false if raw_token.blank? || token_digest.blank?

    self.class.secure_compare(token_digest, self.class.digest(raw_token))
  end

  # Revokes the token so it can no longer authorize stream access (Req 11.5).
  # Idempotent.
  def revoke!
    update!(status: :revoked) unless revoked?
  end

  # A token may authorize stream access only while it is active (Req 11.5).
  def usable?
    active?
  end

  # Keyed digest of a plaintext token. HMAC-SHA256 keyed on the application's
  # secret_key_base yields a deterministic, unique digest suitable for the
  # `token_digest` unique index while never exposing the plaintext.
  def self.digest(raw_token)
    OpenSSL::HMAC.hexdigest("SHA256", digest_key, raw_token.to_s)
  end

  # Locates the token whose stored digest matches the presented plaintext token,
  # confirming with a constant-time comparison. Returns nil when no token
  # matches. Callers still enforce status (see `usable?`) as defense-in-depth.
  def self.find_by_token(raw_token)
    return if raw_token.blank?

    stream_token = find_by(token_digest: digest(raw_token))
    stream_token if stream_token&.authenticate_token(raw_token)
  end

  # Constant-time string comparison tolerant of differing lengths.
  def self.secure_compare(left, right)
    ActiveSupport::SecurityUtils.secure_compare(left.to_s, right.to_s)
  end

  def self.digest_key
    Rails.application.secret_key_base
  end
  private_class_method :digest_key
end
