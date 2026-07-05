class AddCatalogVersionAndCreateCatalogChanges < ActiveRecord::Migration[8.1]
  def change
    # Catalog_Version is a per-Library monotonically non-decreasing integer on
    # the hosting server that increases whenever the Library's Catalog changes
    # through an addition, a metadata update, or a deletion (Req 3.1). Additive
    # and non-null with a default of 0 so existing local libraries start at 0.
    add_column :libraries, :catalog_version, :integer, null: false, default: 0

    # The hosting-side change log. Each row records a single Catalog change so a
    # redeemer can pull only the deltas after its Sync_Cursor (Req 3.4, 3.5).
    create_table :catalog_changes do |t|
      t.references :library, null: false, foreign_key: true
      # The catalog_version of the owning library immediately after this change.
      t.integer :version, null: false
      # song | album | artist
      t.string :item_type, null: false
      # Hosting-side id of the changed item (Req 3.4, 3.5).
      t.integer :item_id, null: false
      # upsert | deletion
      t.string :change_type, null: false

      t.datetime :created_at, null: false
    end

    # Serves ordered, paginated changes_since(cursor) queries: rows with
    # version > cursor ordered by version ascending, scoped per library.
    add_index :catalog_changes, [:library_id, :version]
  end
end
