class CreatePartyOutputDevices < ActiveRecord::Migration[8.1]
  def change
    # Party_Output_Device is the host's selection of which Output_Devices a
    # Party_Session plays to (Req 6.1, 6.2). It is a simple join between a
    # Party_Session and an Output_Device: selecting one or more devices records a
    # row per device, and dispatch (PartyPlaybackDispatcher) plays the
    # Shared_Playlist's current Song on exactly the selected set. When a device
    # becomes unavailable its row is removed so playback continues on the
    # remaining selected devices, and once none remain playback stops (Req 6.4).
    create_table :party_output_devices do |t|
      t.references :party_session, null: false, foreign_key: true
      t.references :output_device, null: false, foreign_key: true

      t.timestamps
    end

    # A device is selected at most once per Party_Session, so re-selecting the
    # same device is idempotent rather than creating a duplicate row.
    add_index :party_output_devices, [ :party_session_id, :output_device_id ],
      unique: true, name: "index_party_output_devices_on_session_and_device"
  end
end
