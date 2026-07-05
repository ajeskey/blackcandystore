class CreateLibraryConnections < ActiveRecord::Migration[8.1]
  def change
    # Library_Connection lives on the redeeming server. It stores how to reach
    # and authenticate against a Remote_Library on another server (Req 5.2, 6.2).
    # grant_token holds the Bearer credential; the column is a plain string here
    # and encryption is applied at the model layer (task 8.2).
    create_table :library_connections do |t|
      t.string :server_base_url
      t.integer :remote_library_id
      t.string :grant_token
      t.references :user, null: false, foreign_key: true
      t.string :status, null: false, default: "active"

      t.timestamps
    end

    # Prevent duplicate connections to the same remote library for a user
    # (Req 5.9).
    add_index :library_connections,
      [ :user_id, :server_base_url, :remote_library_id ],
      unique: true,
      name: "index_library_connections_on_user_and_remote_library"
  end
end
