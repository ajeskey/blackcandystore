class AddRemoteIdsToContentTables < ActiveRecord::Migration[8.1]
  def change
    # Hosting-side identifiers stored on the redeeming Server's mirrored rows so
    # each mirrored item can be referenced back to the item it materializes on
    # the Hosting_Server (Req 7.1). Null for local content, set only for
    # Mirrored_Songs/Albums/Artists in a kind: remote Library. Additive and
    # nullable so existing local content is untouched.
    add_column :songs, :remote_song_id, :integer, null: true
    add_column :albums, :remote_album_id, :integer, null: true
    add_column :artists, :remote_artist_id, :integer, null: true

    # Partial unique indexes enforce the (Library_Connection, hosting-side id)
    # identity of a mirrored item (Req 2.2) and make upserts idempotent (Req
    # 8.2). Because a remote Library has exactly one Library_Connection, scoping
    # by library_id is equivalent to scoping by connection. The WHERE clause
    # limits uniqueness to mirrored rows so the many local rows (remote_*_id
    # IS NULL) are never constrained.
    add_index :songs, [:library_id, :remote_song_id],
      unique: true,
      where: "remote_song_id IS NOT NULL",
      name: "index_songs_on_library_id_and_remote_song_id"

    add_index :albums, [:library_id, :remote_album_id],
      unique: true,
      where: "remote_album_id IS NOT NULL",
      name: "index_albums_on_library_id_and_remote_album_id"

    add_index :artists, [:library_id, :remote_artist_id],
      unique: true,
      where: "remote_artist_id IS NOT NULL",
      name: "index_artists_on_library_id_and_remote_artist_id"
  end
end
