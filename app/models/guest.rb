# frozen_string_literal: true

# A Guest is a non-account participant admitted to a Party_Session or a
# Co_Listen_Session via a Share_Link. Admission binds a Guest_Token to this
# record (Req 5.13); that binding is the stable identity used to enforce
# per-Guest add quotas/rates (Req 5.9) and removal (Req 5.8).
#
# Like AccessGrant, the Guest_Token secret is never stored in plaintext: only
# its keyed digest is persisted in `guest_token_digest` (Req 8.7). Guest API
# requests present the plaintext token as a non-cookie Bearer credential; the
# Server digests the presented token and compares it against stored digests
# with a constant-time comparison so lookup does not leak timing information.
class Guest < ApplicationRecord
  # A Guest belongs polymorphically to whichever session admitted it — a
  # Party_Session or a Co_Listen_Session (Req 5, 7.7).
  belongs_to :sessionable, polymorphic: true

  validates :guest_token_digest, presence: true

  # Assigns the plaintext Guest_Token, storing only its keyed digest. The
  # plaintext is retained in-memory (via `token`) so it can be returned to the
  # admitted Guest exactly once at admission; it is never persisted.
  def token=(raw_token)
    @token = raw_token
    self.guest_token_digest = raw_token.present? ? self.class.digest(raw_token) : nil
  end

  # The plaintext Guest_Token, available only on the in-memory instance that set
  # it (e.g. right after admission). Reloaded records return nil.
  attr_reader :token

  # Constant-time verification of a presented plaintext token against this
  # Guest's stored digest. Returns false rather than raising on blank input.
  def authenticate_token(raw_token)
    return false if raw_token.blank? || guest_token_digest.blank?

    self.class.secure_compare(guest_token_digest, self.class.digest(raw_token))
  end

  # A removed Guest's subsequent requests must be rejected (Req 5.8).
  def removed?
    removed_at.present?
  end

  # A Guest is active while it has not been removed. Callers still enforce the
  # session's own lifecycle/expiration as defense-in-depth.
  def active?
    !removed?
  end

  # Marks the Guest as removed so subsequent requests are rejected (Req 5.8).
  # Idempotent: re-removing keeps the original removal time.
  def remove!(now = Time.current)
    update!(removed_at: now) unless removed?
  end

  # True once the Guest has reached the session's total per-Guest add quota
  # (Req 5.9). A nil quota means unlimited. `add_count` accumulates every
  # accepted addition for the lifetime of the Guest.
  def add_quota_exceeded?
    quota = sessionable&.guest_add_quota
    quota.present? && add_count >= quota
  end

  # True when accepting another addition now would exceed the session's
  # configured per-minute add rate (Req 5.9). Enforced as a minimum spacing of
  # `60 / rate` seconds between accepted additions, anchored on the last
  # accepted addition recorded in `rate_window_started_at`. A nil/zero rate
  # means unlimited.
  def rate_limited?(now: Time.current)
    rate = sessionable&.guest_add_rate_per_minute
    return false if rate.blank? || rate <= 0
    return false if rate_window_started_at.blank?

    (now - rate_window_started_at) < (60.0 / rate)
  end

  # Records one accepted Shared_Playlist addition against this Guest: bumps the
  # lifetime quota counter and stamps the rate window. Persists the change.
  def record_add!(now: Time.current)
    self.add_count += 1
    self.rate_window_started_at = now
    save!
  end

  # Keyed digest of a plaintext token. HMAC-SHA256 keyed on the application's
  # secret_key_base yields a deterministic, unique digest suitable for the
  # `guest_token_digest` unique index while never exposing the plaintext.
  def self.digest(raw_token)
    OpenSSL::HMAC.hexdigest("SHA256", digest_key, raw_token.to_s)
  end

  # Locates the Guest whose stored digest matches the presented plaintext token,
  # confirming with a constant-time comparison. Returns nil when no Guest
  # matches. Callers still enforce removal/session lifecycle (see `active?`).
  def self.find_by_token(raw_token)
    return if raw_token.blank?

    guest = find_by(guest_token_digest: digest(raw_token))
    guest if guest&.authenticate_token(raw_token)
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
