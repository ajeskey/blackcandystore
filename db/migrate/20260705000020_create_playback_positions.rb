class CreatePlaybackPositions < ActiveRecord::Migration[8.1]
  def change
    # Playback_Position_Record stores a User's elapsed play time, in seconds,
    # for a single Resumable_Track, keyed on the (user_id, song_id) pair
    # (Req 6.1, 7.1). This table is deliberately separate from and unrelated to
    # the existing `position` columns, which hold different concepts and must
    # not be reused:
    #   - playback_sessions.position / cast_sessions.position — playlist index.
    #   - playlists_songs.position / shared_playlist_entries.position — ordering.
    # It stores elapsed seconds, so it uses a distinct name (`position_seconds`)
    # to avoid semantic collision.
    create_table :playback_positions do |t|
      t.integer :user_id, null: false
      t.integer :song_id, null: false
      t.float :position_seconds, null: false, default: 0.0  # matches songs.duration (float)
      t.boolean :finished, null: false, default: false

      t.timestamps
    end

    # One Playback_Position_Record per (User, Song) pair (Req 6.1).
    add_index :playback_positions, [ :user_id, :song_id ], unique: true
    # Supports Continue_Listening ordering by last-updated time (Req 4.2).
    add_index :playback_positions, [ :user_id, :updated_at ]

    add_foreign_key :playback_positions, :users
    add_foreign_key :playback_positions, :songs
  end
end
