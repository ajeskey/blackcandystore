class CreateLibrariesAndAddLibraryReferences < ActiveRecord::Migration[8.1]
  def change
    create_table :libraries do |t|
      t.string :name, null: false
      t.string :kind, null: false
      t.string :media_path
      t.references :owner, foreign_key: { to_table: :users }
      t.string :scan_state, null: false, default: "idle"
      t.boolean :is_default, null: false, default: false
      # library_connections is introduced in Phase 2; add the column without a
      # foreign key constraint for now so remote libraries can reference it later.
      t.references :library_connection, index: true, foreign_key: false

      t.timestamps
    end

    # Case-insensitive uniqueness on the library name (Req 1.2, 1.10).
    # A functional index on LOWER(name) works for both SQLite and PostgreSQL.
    add_index :libraries, "LOWER(name)", unique: true, name: "index_libraries_on_lower_name"

    # library_id is nullable now and made NOT NULL after the Phase 1 backfill.
    add_reference :songs, :library, foreign_key: true, null: true
    add_reference :albums, :library, foreign_key: true, null: true
    add_reference :artists, :library, foreign_key: true, null: true
  end
end
