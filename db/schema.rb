# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_07_05_000001) do
  create_table "access_grants", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at"
    t.integer "library_id", null: false
    t.string "nudge_callback_url"
    t.string "nudge_token"
    t.datetime "redeemed_at"
    t.string "redeemer_identity"
    t.integer "redeemer_user_id"
    t.string "status", default: "active", null: false
    t.string "token_digest", null: false
    t.datetime "updated_at", null: false
    t.index ["library_id"], name: "index_access_grants_on_library_id"
    t.index ["redeemer_user_id"], name: "index_access_grants_on_redeemer_user_id"
    t.index ["token_digest"], name: "index_access_grants_on_token_digest", unique: true
  end

  create_table "active_storage_attachments", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "key", null: false
    t.text "metadata"
    t.string "service_name", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "albums", force: :cascade do |t|
    t.integer "artist_id"
    t.datetime "created_at", null: false
    t.text "enrichment"
    t.string "genre"
    t.integer "library_id", null: false
    t.string "name", null: false
    t.integer "remote_album_id"
    t.datetime "updated_at", null: false
    t.integer "year"
    t.index ["artist_id"], name: "index_albums_on_artist_id"
    t.index ["library_id", "artist_id", "name"], name: "index_albums_on_library_id_and_artist_id_and_name", unique: true
    t.index ["library_id", "remote_album_id"], name: "index_albums_on_library_id_and_remote_album_id", unique: true, where: "remote_album_id IS NOT NULL"
    t.index ["library_id"], name: "index_albums_on_library_id"
    t.index ["name"], name: "index_albums_on_name"
  end

  create_table "artists", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "library_id", null: false
    t.string "name", null: false
    t.integer "remote_artist_id"
    t.datetime "updated_at", null: false
    t.boolean "various", default: false
    t.index ["library_id", "name"], name: "index_artists_on_library_id_and_name", unique: true
    t.index ["library_id", "remote_artist_id"], name: "index_artists_on_library_id_and_remote_artist_id", unique: true, where: "remote_artist_id IS NOT NULL"
    t.index ["library_id"], name: "index_artists_on_library_id"
  end

  create_table "cast_sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "current_song_id"
    t.integer "position", default: 0, null: false
    t.string "state", default: "stopped", null: false
    t.integer "target_output_device_id"
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["user_id"], name: "index_cast_sessions_on_user_id", unique: true
  end

  create_table "catalog_changes", force: :cascade do |t|
    t.string "change_type", null: false
    t.datetime "created_at", null: false
    t.integer "item_id", null: false
    t.string "item_type", null: false
    t.integer "library_id", null: false
    t.integer "version", null: false
    t.index ["library_id", "version"], name: "index_catalog_changes_on_library_id_and_version"
    t.index ["library_id"], name: "index_catalog_changes_on_library_id"
  end

  create_table "content_fingerprints", force: :cascade do |t|
    t.string "acoustic_fingerprint"
    t.datetime "created_at", null: false
    t.string "md5_hash"
    t.string "normalized_key"
    t.integer "song_id", null: false
    t.datetime "updated_at", null: false
    t.index ["md5_hash"], name: "index_content_fingerprints_on_md5_hash"
    t.index ["normalized_key"], name: "index_content_fingerprints_on_normalized_key"
    t.index ["song_id"], name: "index_content_fingerprints_on_song_id"
  end

  create_table "duplicate_groups", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "logical_track_key"
    t.datetime "updated_at", null: false
    t.index ["logical_track_key"], name: "index_duplicate_groups_on_logical_track_key"
  end

  create_table "libraries", force: :cascade do |t|
    t.integer "catalog_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.boolean "is_default", default: false, null: false
    t.string "kind", null: false
    t.integer "library_connection_id"
    t.string "media_path"
    t.string "name", null: false
    t.integer "owner_id"
    t.string "scan_state", default: "idle", null: false
    t.datetime "updated_at", null: false
    t.index "LOWER(name)", name: "index_libraries_on_lower_name", unique: true
    t.index ["library_connection_id"], name: "index_libraries_on_library_connection_id"
    t.index ["owner_id"], name: "index_libraries_on_owner_id"
  end

  create_table "library_connections", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "grant_token"
    t.datetime "last_synced_at"
    t.string "nudge_token"
    t.integer "remote_library_id"
    t.string "server_base_url"
    t.string "status", default: "active", null: false
    t.integer "sync_cursor", default: 0, null: false
    t.string "sync_state", default: "fresh", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["nudge_token"], name: "index_library_connections_on_nudge_token", unique: true
    t.index ["user_id", "server_base_url", "remote_library_id"], name: "index_library_connections_on_user_and_remote_library", unique: true
    t.index ["user_id"], name: "index_library_connections_on_user_id"
  end

  create_table "output_devices", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "identifier", null: false
    t.string "name"
    t.string "protocol"
    t.datetime "reachable_at"
    t.boolean "requires_password", default: false, null: false
    t.datetime "updated_at", null: false
    t.index ["identifier"], name: "index_output_devices_on_identifier", unique: true
  end

  create_table "playback_sessions", force: :cascade do |t|
    t.text "active_output_device_ids"
    t.datetime "created_at", null: false
    t.integer "current_song_id"
    t.integer "position", default: 0, null: false
    t.string "state", default: "stopped", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["user_id"], name: "index_playback_sessions_on_user_id"
  end

  create_table "playlists", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name"
    t.string "type"
    t.datetime "updated_at", null: false
    t.integer "user_id"
    t.index ["name"], name: "index_playlists_on_name"
    t.index ["user_id"], name: "index_playlists_on_user_id"
  end

  create_table "playlists_songs", force: :cascade do |t|
    t.integer "playlist_id", null: false
    t.integer "position"
    t.integer "song_id", null: false
    t.index ["song_id", "playlist_id"], name: "index_playlists_songs_on_song_id_and_playlist_id", unique: true
  end

  create_table "sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "ip_address"
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.integer "user_id", null: false
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "settings", force: :cascade do |t|
    t.integer "singleton_guard"
    t.text "values"
    t.index ["singleton_guard"], name: "index_settings_on_singleton_guard", unique: true
  end

  create_table "songs", force: :cascade do |t|
    t.integer "album_id"
    t.integer "artist_id"
    t.integer "bit_depth"
    t.datetime "created_at", null: false
    t.integer "discnum"
    t.integer "duplicate_group_id"
    t.float "duration", default: 0.0, null: false
    t.string "file_path"
    t.string "file_path_hash"
    t.integer "library_id", null: false
    t.string "md5_hash"
    t.string "name", null: false
    t.integer "remote_song_id"
    t.integer "tracknum"
    t.datetime "updated_at", null: false
    t.index ["album_id"], name: "index_songs_on_album_id"
    t.index ["artist_id"], name: "index_songs_on_artist_id"
    t.index ["duplicate_group_id"], name: "index_songs_on_duplicate_group_id"
    t.index ["file_path_hash"], name: "index_songs_on_file_path_hash"
    t.index ["library_id", "md5_hash"], name: "index_songs_on_library_id_and_md5_hash", unique: true
    t.index ["library_id", "remote_song_id"], name: "index_songs_on_library_id_and_remote_song_id", unique: true, where: "remote_song_id IS NOT NULL"
    t.index ["library_id"], name: "index_songs_on_library_id"
    t.index ["name"], name: "index_songs_on_name"
  end

  create_table "users", force: :cascade do |t|
    t.integer "active_library_id"
    t.datetime "created_at", null: false
    t.string "deprecated_password_salt"
    t.string "email", null: false
    t.boolean "is_admin", default: false
    t.string "password_digest", null: false
    t.text "recently_played_album_ids"
    t.text "settings"
    t.datetime "updated_at", null: false
    t.index ["active_library_id"], name: "index_users_on_active_library_id"
    t.index ["email"], name: "index_users_on_email", unique: true
  end

  add_foreign_key "access_grants", "libraries"
  add_foreign_key "access_grants", "users", column: "redeemer_user_id"
  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "albums", "libraries"
  add_foreign_key "artists", "libraries"
  add_foreign_key "cast_sessions", "users"
  add_foreign_key "catalog_changes", "libraries"
  add_foreign_key "content_fingerprints", "songs"
  add_foreign_key "libraries", "users", column: "owner_id"
  add_foreign_key "library_connections", "users"
  add_foreign_key "playback_sessions", "users"
  add_foreign_key "songs", "duplicate_groups"
  add_foreign_key "songs", "libraries"
  add_foreign_key "users", "libraries", column: "active_library_id", on_delete: :nullify
end
