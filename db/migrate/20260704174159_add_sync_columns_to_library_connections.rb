class AddSyncColumnsToLibraryConnections < ActiveRecord::Migration[8.1]
  def change
    # Synchronization state for the redeeming Server's Catalog_Mirror. These
    # columns are additive and nullable/defaulted so existing Library_Connections
    # are untouched. They are distinct from the existing lifecycle `status`
    # column (active | revoked | unavailable), which tracks the connection/grant
    # lifecycle; the columns below track the mirror's freshness.

    # Highest Catalog_Version the redeemer has successfully applied for this
    # connection. Presented to the Changes_Since_API to request only subsequent
    # changes (Req 4.3).
    add_column :library_connections, :sync_cursor, :integer, null: false, default: 0

    # Timestamp of the most recent successful Full_Sync or Incremental_Sync
    # (Req 4.6). Null until the first successful sync.
    add_column :library_connections, :last_synced_at, :datetime, null: true

    # The mirror's freshness: fresh (last sync succeeded), stale (last attempt
    # failed or the mirror is past its staleness threshold, last-known mirror
    # retained), or unavailable (mirror torn down on revocation/unavailability/
    # deletion). Distinct from the lifecycle `status` column (Req 4.6, 9.1, 10.1).
    add_column :library_connections, :sync_state, :string, null: false, default: "fresh"

    # Opaque per-connection token for the redeemer's Nudge_Endpoint. Nullable
    # (a connection without a token simply relies on the scheduled pull) and
    # uniquely indexed so a received nudge maps to at most one connection
    # (Req 6.5).
    add_column :library_connections, :nudge_token, :string, null: true

    add_index :library_connections, :nudge_token,
      unique: true,
      name: "index_library_connections_on_nudge_token"
  end
end
