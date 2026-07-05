class CreateCastSessions < ActiveRecord::Migration[8.1]
  def change
    # Cast_Session holds the client-side `client_cast` playback state for a User
    # (Req 17). Under the `client_cast` Playback_Mode the Web_Player/App_Player is
    # the audio source and casts audio directly to a single target Output_Device;
    # the Server keeps this lightweight record only for bookkeeping so the
    # activity is managed through a Cast_Session and never through a
    # Playback_Session (Req 18.2, 18.3).
    #
    # `state` is one of `stopped｜playing｜paused` (state invariant, Req 17.14).
    # `position` is the retained playback position in seconds (Req 17.6, 17.16).
    # `current_song_id` and `target_output_device_id` are plain integers rather
    # than foreign keys: the cast Song may live on a Remote_Library and therefore
    # not exist in this server's `songs` table, and the target device is a
    # discovery-maintained, network-ephemeral endpoint tracked client-side.
    #
    # A User drives one client-cast activity at a time from a given client, so
    # the bookkeeping record is one-per-user (find_or_initialize on create),
    # enforced by the unique index on `user_id`.
    create_table :cast_sessions do |t|
      t.references :user, null: false, foreign_key: true, index: { unique: true }
      t.string :state, null: false, default: "stopped"
      t.integer :current_song_id
      t.integer :target_output_device_id
      t.integer :position, null: false, default: 0

      t.timestamps
    end
  end
end
