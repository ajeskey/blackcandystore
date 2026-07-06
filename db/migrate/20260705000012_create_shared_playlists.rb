class CreateSharedPlaylists < ActiveRecord::Migration[8.1]
  def change
    # Shared_Playlist is the collaborative playlist owned by a Party_Session or
    # a Co_Listen_Session (polymorphic `sessionable`). It is retained after the
    # session ends for the Host to review (Req 12.3).
    create_table :shared_playlists do |t|
      t.references :sessionable, polymorphic: true, null: false

      t.timestamps
    end

    # A session owns at most one Shared_Playlist (has_one).
    add_index :shared_playlists, [ :sessionable_type, :sessionable_id ], unique: true, name: "index_shared_playlists_on_sessionable_unique"

    # Shared_Playlist_Entry is a single Song placed in a Shared_Playlist, ordered
    # by `position` (Req 6.3) and attributed to its adder (Req 5.12).
    create_table :shared_playlist_entries do |t|
      t.references :shared_playlist, null: false, foreign_key: true

      # The added Song. Stored as a plain integer (not a foreign key) because a
      # Song in a shared Library may live on a Remote_Library and therefore not
      # exist in this server's `songs` table.
      t.integer :song_id, null: false

      # Ordering within the playlist (Req 6.3).
      t.integer :position, null: false, default: 0

      # Adder attribution (Req 5.12). Exactly one of guest/user is set. The guest
      # reference is a plain integer (no foreign key) because the `guests` table
      # is created independently; the user reference is a nullable foreign key.
      t.integer :added_by_guest_id
      t.references :added_by_user, foreign_key: { to_table: :users }, null: true

      # Snapshot of the Guest_Display_Name at add time so attribution survives
      # even after the Guest record changes (Req 5.12).
      t.string :guest_display_name

      t.timestamps
    end

    add_index :shared_playlist_entries, [ :shared_playlist_id, :position ]
    add_index :shared_playlist_entries, :added_by_guest_id
  end
end
