class NullifyUsersActiveLibraryOnDelete < ActiveRecord::Migration[8.1]
  def up
    # The original active_library foreign key must nullify a user's stale
    # selection when the referenced library is destroyed (Req 3.1, 3.5). The
    # schema captured the key without `on_delete: :nullify`, so destroying a
    # referenced library raised a FOREIGN KEY constraint failure. Recreate the
    # key with the nullify behavior so a deleted library clears the selection at
    # the database level as well as in the application cascade.
    remove_foreign_key :users, column: :active_library_id
    add_foreign_key :users, :libraries, column: :active_library_id, on_delete: :nullify
  end

  def down
    remove_foreign_key :users, column: :active_library_id
    add_foreign_key :users, :libraries, column: :active_library_id
  end
end
