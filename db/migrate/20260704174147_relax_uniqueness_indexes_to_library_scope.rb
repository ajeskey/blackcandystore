class RelaxUniquenessIndexesToLibraryScope < ActiveRecord::Migration[8.1]
  def up
    # Songs: the same media file may exist under two different libraries, so
    # md5_hash is only unique within a library, not globally (Req 2.3).
    remove_index :songs, :md5_hash, name: "index_songs_on_md5_hash"
    add_index :songs, [ :library_id, :md5_hash ], unique: true, name: "index_songs_on_library_id_and_md5_hash"

    # Albums: each library owns its own album rows; cross-library grouping is
    # handled logically by the Deduplicator, not by shared rows (Req 12.5).
    remove_index :albums, [ :artist_id, :name ], name: "index_albums_on_artist_id_and_name"
    add_index :albums, [ :library_id, :artist_id, :name ], unique: true, name: "index_albums_on_library_id_and_artist_id_and_name"

    # Artists: likewise scoped per library (Req 12.5).
    remove_index :artists, :name, name: "index_artists_on_name"
    add_index :artists, [ :library_id, :name ], unique: true, name: "index_artists_on_library_id_and_name"
  end

  def down
    remove_index :artists, [ :library_id, :name ], name: "index_artists_on_library_id_and_name"
    add_index :artists, :name, unique: true, name: "index_artists_on_name"

    remove_index :albums, [ :library_id, :artist_id, :name ], name: "index_albums_on_library_id_and_artist_id_and_name"
    add_index :albums, [ :artist_id, :name ], unique: true, name: "index_albums_on_artist_id_and_name"

    remove_index :songs, [ :library_id, :md5_hash ], name: "index_songs_on_library_id_and_md5_hash"
    add_index :songs, :md5_hash, unique: true, name: "index_songs_on_md5_hash"
  end
end
