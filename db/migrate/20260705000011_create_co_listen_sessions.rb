class CreateCoListenSessions < ActiveRecord::Migration[8.1]
  def change
    # Co_Listen_Session is a Host-created session combining a Radio-style
    # Shared_Stream with a collaborative Shared_Playlist, where each participant
    # listens on their own device (Req 7.1). It carries the same sharing,
    # duration, and guest configuration as a Party_Session (Req 7.7) plus a
    # `listener_limit` (Req 11.6). It has no `stream_visibility` — a co-listen
    # stream is never public (Req 11.8).
    create_table :co_listen_sessions do |t|
      # Host who owns the session (Req 7.1).
      t.references :user, null: false, foreign_key: true

      # Session_State — `active` (running) or `ended` (Req 10.7, 10.8).
      t.string :state, null: false, default: "active"

      # Session_Duration (Req 4.3 via 7.7).
      t.string :session_duration_kind, null: false, default: "perpetual"
      t.integer :session_duration_value

      # Duplicate handling for Shared_Playlist adds (Req 5.10 via 7.7).
      t.string :duplicate_policy, null: false, default: "reject"

      # Guest configuration (Req 5.9, 5.11 via 7.7).
      t.integer :max_guests
      t.integer :guest_add_quota
      t.integer :guest_add_rate_per_minute

      # Maximum number of concurrent Listeners on the Shared_Stream (Req 11.6).
      # Null means unbounded.
      t.integer :listener_limit

      # Shared libraries chosen from the host's authorized libraries (Req 4.7 via
      # 7.7). jsonb on PostgreSQL, json on SQLite.
      if connection.adapter_name.downcase.include?("postgres")
        t.jsonb :shared_library_ids, null: false, default: []
      else
        t.json :shared_library_ids, null: false, default: []
      end

      t.timestamps
    end
  end
end
