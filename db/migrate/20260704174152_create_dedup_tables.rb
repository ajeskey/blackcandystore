class CreateDedupTables < ActiveRecord::Migration[8.1]
  def change
    # Duplicate_Group represents one Logical_Track that a set of Songs across
    # libraries/servers resolve to. logical_track_key is the stable identity of
    # that logical track used to look up / build the group (Req 12.3).
    create_table :duplicate_groups do |t|
      t.string :logical_track_key

      t.timestamps
    end

    add_index :duplicate_groups, :logical_track_key

    # Content_Fingerprint is the per-song signature the Deduplicator compares to
    # decide whether two Songs are the same content (Req 12.1, 12.2).
    # normalized_key is the "name|artist|album|duration" metadata signature and
    # acoustic_fingerprint is the optional fpcalc value.
    create_table :content_fingerprints do |t|
      t.references :song, null: false, foreign_key: true
      t.string :md5_hash
      t.string :acoustic_fingerprint
      t.string :normalized_key

      t.timestamps
    end

    add_index :content_fingerprints, :md5_hash
    add_index :content_fingerprints, :normalized_key

    # Songs that resolve to the same Logical_Track share a Duplicate_Group.
    # Nullable because ungrouped songs (no known duplicates) have no group yet
    # (Req 12.3).
    add_reference :songs, :duplicate_group, null: true, foreign_key: true
  end
end
