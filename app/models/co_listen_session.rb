# frozen_string_literal: true

# Co_Listen_Session combines a Radio-style always-on Shared_Stream with a
# collaborative Shared_Playlist: participants add Songs and each listens on their
# own device rather than to a single shared Output_Device (Req 7.1, 7.5). It
# carries the same Guest sharing, library scoping, time-boxing, and revocation
# rules as a Party_Session (Req 7.7) — all supplied by SharedSessionConcern —
# and adds a `listener_limit` capping concurrent Listeners on its Shared_Stream
# (Req 11.6).
#
# A Co_Listen_Session Shared_Stream is never public: it is always authorized by
# a per-participant guest-scoped Stream_Token (Req 11.8), so this model has no
# `stream_visibility` column.
class CoListenSession < ApplicationRecord
  include SharedSessionConcern

  # Maximum number of concurrent Listeners the Shared_Stream will serve; nil
  # means unbounded (Req 11.6).
  validates :listener_limit, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
end
