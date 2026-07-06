class CreateRadioStationsAndStationSourceCriteria < ActiveRecord::Migration[8.1]
  def change
    # Radio_Station is a User-defined configuration from which the Server
    # assembles a continuous, always-on Shared_Stream (Req 1.1). Its eligible
    # Songs are derived at query time from its Station_Source_Criteria
    # intersected with the owner's authorized libraries, so no eligible-song
    # set is persisted here.
    create_table :radio_stations do |t|
      # Owner of the station; authority for mutation/lifecycle (Req 1.1, 1.8).
      t.references :user, null: false, foreign_key: true
      # Display name, validated 1..255 non-blank at the model layer (Req 1.1, 1.6).
      t.string :name, null: false
      # Station_State lifecycle: `stopped` (not broadcasting) or `started`
      # (broadcasting a Shared_Stream). Defaults to `stopped` (Req 10.1, 10.2).
      t.string :state, null: false, default: "stopped"
      # Stream_Visibility: `authenticated` (Stream_Token or authorized account)
      # or `public` (served without credentials). Defaults to `authenticated`
      # (Req 11.1).
      t.string :stream_visibility, null: false, default: "authenticated"
      # Optional maximum concurrent Listeners for this station's Shared_Stream
      # (Req 11.6); nil means no owner-configured limit.
      t.integer :listener_limit, null: true

      t.timestamps
    end

    # Station_Source_Criteria define which Songs are eligible for a station's
    # program. Any combination of Artists, specific Songs, and Genres is allowed
    # (Req 1.2). Each row carries a single criterion of one `criterion_type`
    # (`artist`/`song`/`genre`) with the matching value column populated.
    create_table :station_source_criteria do |t|
      t.references :radio_station, null: false, foreign_key: true
      # One of `artist`, `song`, or `genre` (Req 1.2).
      t.string :criterion_type, null: false
      # Value columns; exactly one is populated per row according to
      # `criterion_type`. artist_id/song_id reference existing content;
      # genre is a free-text metadata value (matching the `genre` column on
      # albums).
      t.references :artist, null: true, foreign_key: true
      t.references :song, null: true, foreign_key: true
      t.string :genre, null: true

      t.timestamps
    end

    # Speeds up filtering a station's criteria by type when recomputing the
    # eligible-song set on create/update (Req 1.5).
    add_index :station_source_criteria, [ :radio_station_id, :criterion_type ]
  end
end
