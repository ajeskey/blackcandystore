class CreatePlaybackTables < ActiveRecord::Migration[8.1]
  def change
    # Output_Device is a discovery-maintained cache row describing an AirPlay or
    # Chromecast target advertised on the local network (Req 13.1, 13.2, 13.6).
    # `identifier` is the stable, protocol-level device id used to add/remove a
    # device as advertisements appear and disappear. `reachable_at` records when
    # the device was last seen reachable by Device_Discovery.
    create_table :output_devices do |t|
      t.string :identifier, null: false
      t.string :name
      t.string :protocol
      t.boolean :requires_password, null: false, default: false
      t.datetime :reachable_at

      t.timestamps
    end

    # A discovered device is uniquely identified by its protocol-level id, so
    # re-discovering the same device updates the existing row rather than
    # creating a duplicate (Req 13.3).
    add_index :output_devices, :identifier, unique: true

    # Playback_Session holds the server-driven playback state for a User under
    # the `server_playback` Playback_Mode (Req 14.1, 14.15). `state` is one of
    # `stopped｜playing｜paused` (state invariant, Req 14.15). `position` is the
    # retained playback position in seconds. `active_output_device_ids` is the
    # serialized set of Output_Devices currently receiving audio for the
    # session. `current_song_id` is a plain integer rather than a foreign key
    # because the current Song may live on a Remote_Library and therefore not
    # exist in this server's `songs` table.
    create_table :playback_sessions do |t|
      t.references :user, null: false, foreign_key: true
      t.string :state, null: false, default: "stopped"
      t.integer :current_song_id
      t.integer :position, null: false, default: 0
      t.text :active_output_device_ids

      t.timestamps
    end
  end
end
