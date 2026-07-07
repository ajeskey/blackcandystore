# frozen_string_literal: true

# Pure decision seam for the Continue_Listening_List (no I/O). Given a set of
# already-loaded Playback_Position_Records and the set of library ids the
# current User may access, it filters, orders, and caps the list without
# touching the database.
#
# Each record must respond to position_seconds, finished, updated_at, and
# library_id. References the fixed MINIMUM_RESUME_POSITION constant defined on
# the PlaybackPosition model so Ruby and JS never drift.
module Playback::ContinueListeningPolicy
  MAX_ITEMS = 20

  module_function

  # Pure filter/order/cap over already-loaded records. Keeps only records at or
  # above the Minimum_Resume_Position (Req 4.1), that are not finished (Req 4.3,
  # 5.3), and whose Song belongs to an authorized library (Req 4.4); orders by
  # last-updated time most-recent-first (Req 4.2) and caps at MAX_ITEMS (Req 4.6).
  def select(records, authorized_library_ids:)
    allowed = authorized_library_ids.to_set

    records
      .select { |r| r.position_seconds >= PlaybackPosition::MINIMUM_RESUME_POSITION }  # Req 4.1
      .reject(&:finished)                                                              # Req 4.3, 5.3
      .select { |r| allowed.include?(r.library_id) }                                   # Req 4.4
      .sort_by { |r| r.updated_at }.reverse                                            # Req 4.2
      .first(MAX_ITEMS)                                                                # Req 4.6
  end
end
