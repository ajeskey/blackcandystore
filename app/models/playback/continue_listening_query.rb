# frozen_string_literal: true

# Thin DB adapter for the Continue_Listening_List. It eager-loads the current
# User's Playback_Position_Records joined to their Songs and Albums (bounded to
# the most-recently-updated RECENT_LIMIT so the query stays cheap) and hands the
# already-loaded records to the pure Playback::ContinueListeningPolicy seam,
# which does the filtering, ordering, and capping (Req 4.1, 4.2, 4.3, 4.4, 4.6).
#
# Reads are scoped exclusively to `user.playback_positions`, so a User only ever
# sees their own records (Req 7.3). An empty relation yields an empty list
# without error (Req 4.7). The Album is eager-loaded because the JSON/Home
# surface renders audiobook enrichment for each item and to avoid N+1 lookups
# through the `library_id` delegation used by the policy.
module Playback
  class ContinueListeningQuery
    # Generous upper bound on records pulled from the DB before the pure policy
    # narrows them to at most MAX_ITEMS. Kept well above MAX_ITEMS so that, after
    # filtering out below-threshold/finished/unauthorized records, enough
    # candidates remain to fill the list.
    RECENT_LIMIT = 100

    def initialize(user)
      @user = user
    end

    def call
      records = @user
        .playback_positions
        .includes(song: :album)
        .order(updated_at: :desc)
        .limit(RECENT_LIMIT)
        .to_a

      Playback::ContinueListeningPolicy.select(
        records,
        authorized_library_ids: @user.authorized_library_ids
      )
    end
  end
end
