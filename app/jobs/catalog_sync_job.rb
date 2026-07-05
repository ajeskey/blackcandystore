# frozen_string_literal: true

# CatalogSyncJob drives a Catalog_Mirror synchronization for a single
# Library_Connection on the redeeming Server. It is the queued entry point the
# Sync_Scheduler, the first-connection Full_Sync hook, and the Nudge_Endpoint
# all enqueue onto SolidQueue; the actual reconciliation lives in the pure
# `CatalogSync` engine.
#
# `mode` selects the driver:
#   :incremental (default) — pull only Catalog_Changes after the recorded
#                            Sync_Cursor and apply them (Req 4.2, 4.3).
#   :full                  — replace the whole mirror with the host's current
#                            Catalog (Req 1.1), used on connection establishment
#                            and when the host signals a full sync is required.
#
# A missing connection (deleted between enqueue and run) is a no-op so a stale
# job never raises.
class CatalogSyncJob < ApplicationJob
  queue_as :default

  def perform(library_connection_id, mode: :incremental)
    connection = LibraryConnection.find_by(id: library_connection_id)
    return if connection.nil?

    case mode.to_sym
    when :full
      CatalogSync.full_sync(connection)
    else
      CatalogSync.incremental_sync(connection)
    end
  end

  # Sync_Scheduler entry point (Req 4.1). Invoked by the recurring task in
  # config/recurring.yml every Poll_Interval; enqueues exactly one incremental
  # CatalogSyncJob per active Library_Connection so each mirror is reconciled on
  # the schedule. Uses `find_each` to stay memory-bounded as connections grow.
  def self.enqueue_all_active
    LibraryConnection.active.find_each do |connection|
      perform_later(connection.id, mode: :incremental)
    end
  end
end
