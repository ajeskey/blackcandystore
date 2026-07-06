class CreatePartySessions < ActiveRecord::Migration[8.1]
  def change
    # Party_Session is a Host-created listening session in which Guests add Songs
    # to a Shared_Playlist and audio plays to Host-selected Output_Devices
    # (Req 4.1). It is scoped to specific shared libraries, time-boxed, and
    # revocable.
    create_table :party_sessions do |t|
      # Host who owns the session (Req 4.1, 6.2).
      t.references :user, null: false, foreign_key: true

      # Session_State — `active` (running) or `ended` (deactivated/expired/torn
      # down) (Req 10, 12).
      t.string :state, null: false, default: "active"

      # Session_Duration (Req 4.3): `session_duration_kind` is one of
      # `hours｜days｜perpetual`; `session_duration_value` is the bounded number
      # of hours/days and is null for `perpetual`.
      t.string :session_duration_kind, null: false, default: "perpetual"
      t.integer :session_duration_value

      # Duplicate handling for Shared_Playlist adds — `reject` or `allow`
      # (Req 5.10).
      t.string :duplicate_policy, null: false, default: "reject"

      # Guest configuration (Req 5.9, 5.11): admission cap, per-Guest add quota,
      # and per-Guest add rate per minute. Null means unbounded.
      t.integer :max_guests
      t.integer :guest_add_quota
      t.integer :guest_add_rate_per_minute

      # Libraries the session shares, chosen from the host's authorized libraries
      # (Req 4.7). Stored as jsonb on PostgreSQL and json on SQLite.
      if connection.adapter_name.downcase.include?("postgres")
        t.jsonb :shared_library_ids, null: false, default: []
      else
        t.json :shared_library_ids, null: false, default: []
      end

      t.timestamps
    end
  end
end
