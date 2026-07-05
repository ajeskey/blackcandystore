class AddActiveLibraryToUsers < ActiveRecord::Migration[8.1]
  def change
    # Persisted Active_Library selection for a user. Nullable because a user may
    # have made no selection yet (the default-selection logic fills it in when
    # exactly one library is accessible — Req 3.1, 3.5). References libraries
    # with a foreign key so a deleted library nullifies the stale selection.
    add_reference :users, :active_library, foreign_key: { to_table: :libraries, on_delete: :nullify }, null: true
  end
end
