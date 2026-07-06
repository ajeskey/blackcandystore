# frozen_string_literal: true

# Shared behavior for the two Host-created social-listening sessions:
# Party_Session and Co_Listen_Session. Both own a Shared_Playlist, admit Guests
# through Share_Links, are scoped to a subset of the host's authorized
# libraries, are time-boxed by a Session_Duration, and enforce the same
# per-Guest add quota/rate and duplicate policy (Req 4, 5, 7.7). Extracting the
# common columns, enums, associations, and validations here keeps the two
# models in lockstep and avoids duplication; Co_Listen_Session layers a
# `listener_limit` on top (Req 11.6).
module SharedSessionConcern
  extend ActiveSupport::Concern

  # Session_State — `active` while the session is running, `ended` once the Host
  # deactivates it, it expires, or it is torn down (Req 10, 12).
  SESSION_STATES = { active: "active", ended: "ended" }.freeze

  # Session_Duration kinds: a bounded number of `hours`/`days`, or `perpetual`
  # (no expiration) (Req 4.3, 8.3).
  SESSION_DURATION_KINDS = { hours: "hours", days: "days", perpetual: "perpetual" }.freeze

  # Duplicate handling when a Song already present is added again (Req 5.10).
  DUPLICATE_POLICIES = { reject: "reject", allow: "allow" }.freeze

  included do
    # Host who owns and configures the session (Req 4.1, 7.1).
    belongs_to :user

    # The collaborative playlist the Host and Guests contribute to. Polymorphic
    # so a single Shared_Playlist model serves both session kinds; retained
    # after teardown for host review, so no dependent destroy (Req 12.3).
    has_one :shared_playlist, as: :sessionable

    # Guests admitted through a Share_Link (Req 5.1) and the Share_Links that
    # admit them (Req 4.2). Both are polymorphic on `sessionable`.
    has_many :guests, as: :sessionable
    has_many :share_links, as: :sessionable

    enum :state, SESSION_STATES, default: :active
    enum :session_duration_kind, SESSION_DURATION_KINDS, default: :perpetual, prefix: :duration
    enum :duplicate_policy, DUPLICATE_POLICIES, default: :reject, prefix: :duplicates

    # Normalize the shared-library id list to a de-duplicated set of integers so
    # the subset check compares like-typed ids regardless of how the jsonb
    # column round-trips them.
    normalizes :shared_library_ids, with: ->(ids) { Array(ids).map(&:to_i).uniq }

    # A duration expressed as hours/days requires a positive value; `perpetual`
    # carries no value (Req 4.3, 4.4, 4.5).
    validates :session_duration_value,
      numericality: { only_integer: true, greater_than: 0 },
      if: :bounded_duration?
    validates :session_duration_value, absence: true, if: :duration_perpetual?

    # Guest configuration caps are optional (nil = unbounded) but must be
    # sensible when set (Req 5.9, 5.11).
    validates :max_guests, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
    validates :guest_add_quota, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
    validates :guest_add_rate_per_minute, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true

    # The shared libraries must be a subset of the libraries the Host is
    # authorized to access, so a session can never widen the Host's own access
    # (Req 4.7; Property 13).
    validate :shared_libraries_within_host_authorization
  end

  # True when the Session_Duration is a bounded number of hours or days (i.e.
  # not `perpetual`).
  def bounded_duration?
    duration_hours? || duration_days?
  end

  private

  def shared_libraries_within_host_authorization
    return if user.blank?

    authorized = Array(user.authorized_library_ids).map(&:to_i)
    unless Array(shared_library_ids).all? { |id| authorized.include?(id) }
      errors.add(:shared_library_ids, "must be a subset of the host's authorized libraries")
    end
  end
end
