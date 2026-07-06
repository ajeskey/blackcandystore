# frozen_string_literal: true

require "securerandom"

# ShareLinkService mints and revokes the Share_Links a Host hands out to invite
# Guests into a Party_Session or Co_Listen_Session (Req 4.2, 8.1). It is the
# single seam that translates a session's Session_Duration into the backing
# Access_Grant's `expires_at` (Req 4.4, 4.5, 8.3) and that revokes those grants
# to block new joins (Req 4.6, 8.5).
#
# Each Share_Link is backed by exactly one Access_Grant. Because an
# Access_Grant `belongs_to :library`, a session that shares several libraries is
# modeled as one grant (one Share_Link) per shared library, keeping the proven
# `usable?` / `find_by_token` semantics of AccessGrant intact (design: Data
# Models — ShareLink; Req 8.1, 8.2).
module ShareLinkService
  # Bytes of cryptographic randomness in a generated secret token. 16 bytes =
  # 128 bits, matching InviteManager's Access_Grant tokens (Req 8.7).
  SECRET_TOKEN_BYTES = 16

  module_function

  # Generate the Share_Links for `session`, one Access_Grant-backed link per
  # shared library. Each backing grant's `expires_at` is derived from the
  # session's Session_Duration (Req 4.4, 4.5, 8.3). The whole set is created in
  # a single transaction so a session never ends up with a partial set of
  # links.
  #
  # @param session [PartySession, CoListenSession] the session to share
  # @param now [Time] the reference time the expiration is measured from
  #   (defaults to the current time; injectable for deterministic tests)
  # @return [Array<ShareLink>] the persisted Share_Links, one per shared library
  def generate(session, now: Time.current)
    expires_at = expires_at_for(
      kind: session.session_duration_kind,
      value: session.session_duration_value,
      created_at: now
    )

    ShareLink.transaction do
      Array(session.shared_library_ids).map do |library_id|
        create_link(session: session, library_id: library_id, expires_at: expires_at)
      end
    end
  end

  # Revoke every Access_Grant backing `session`'s Share_Links so that no further
  # Guest may join (Req 4.6, 8.5). Revocation is terminal and does not touch
  # already-admitted Guests, whose access ends only when the session expires or
  # ends. Returns the number of grants revoked.
  #
  # @param session [PartySession, CoListenSession]
  # @return [Integer] count of Access_Grants transitioned to revoked
  def revoke(session)
    grant_ids = session.share_links.pluck(:access_grant_id).uniq
    return 0 if grant_ids.empty?

    AccessGrant.where(id: grant_ids).active.update_all(status: "revoked")
  end

  # Pure mapping from a Session_Duration to an Access_Grant expiration time.
  #
  # A duration of `hours` or `days` yields `created_at` advanced by that many
  # hours/days (Req 4.4, 8.3); a `perpetual` duration yields nil, meaning the
  # grant never expires (Req 4.5). Kept free of any persistence so it can be
  # exercised directly by Property 12.
  #
  # @param kind [String, Symbol] one of `hours`, `days`, `perpetual`
  # @param value [Integer, nil] the number of hours/days (ignored for perpetual)
  # @param created_at [Time] the reference time the duration is measured from
  # @return [Time, nil] the expiration time, or nil for a perpetual duration
  def expires_at_for(kind:, value:, created_at:)
    case kind.to_s
    when "hours" then created_at + Integer(value).hours
    when "days" then created_at + Integer(value).days
    when "perpetual" then nil
    else
      raise ArgumentError, "unknown session duration kind: #{kind.inspect}"
    end
  end

  # Build and persist a single Access_Grant + Share_Link pair for one shared
  # library. The plaintext token exists only in memory on the returned grant
  # (via AccessGrant#token); only its keyed digest is stored (Req 8.7).
  def create_link(session:, library_id:, expires_at:)
    grant = AccessGrant.new(library_id: library_id, expires_at: expires_at, status: :active)
    grant.token = SecureRandom.hex(SECRET_TOKEN_BYTES)
    grant.save!

    session.share_links.create!(access_grant: grant)
  end
  private_class_method :create_link
end
