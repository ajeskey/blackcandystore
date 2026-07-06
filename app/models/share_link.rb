# frozen_string_literal: true

# A Share_Link is the shareable handle a Host hands out to invite Guests into a
# Party_Session or Co_Listen_Session (Req 4.2, 8.1). Its credential and
# lifecycle are delegated entirely to a backing AccessGrant, reusing that
# model's proven keyed-digest token, `usable?` semantics, `expires_at`
# time-boxing, and revocation (Req 4.4-4.6, 8.2, 8.5, 8.7).
#
# Because AccessGrant is scoped to a single Library, a session that shares
# multiple libraries is modeled as one Share_Link (one grant) per shared
# library, keeping the existing grant semantics intact.
class ShareLink < ApplicationRecord
  # A Share_Link belongs polymorphically to the session it shares — a
  # Party_Session or a Co_Listen_Session (Req 4.2, 7.7).
  belongs_to :sessionable, polymorphic: true

  # Exactly one AccessGrant backs each Share_Link (one grant per shared
  # library, Req 8.1, 8.2).
  belongs_to :access_grant

  # A Share_Link may admit new Guests only while its backing grant is usable
  # (active and not expired, Req 8.5). Delegated so callers use a single
  # source of truth for link validity.
  delegate :usable?, :expired?, :active?, :revoked?, to: :access_grant, allow_nil: true
end
