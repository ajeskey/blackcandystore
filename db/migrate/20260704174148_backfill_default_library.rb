class BackfillDefaultLibrary < ActiveRecord::Migration[8.1]
  # Lightweight, migration-local model so this data migration is decoupled from
  # any future changes to (and validations on) the application `Library` model.
  class MigrationLibrary < ActiveRecord::Base
    self.table_name = "libraries"
  end

  BACKFILLED_TABLES = %i[songs albums artists].freeze

  # Creates the Default_Library and associates all pre-existing content with it
  # so a single-media-path deployment behaves identically after upgrade
  # (Req 1.7, 8.8, 9.5). Existing ActiveStorage `cover_image` attachments and
  # stream paths are left untouched — only the new `library_id` association is set.
  def up
    default_library = MigrationLibrary.find_by(is_default: true)

    unless default_library
      default_library = MigrationLibrary.create!(
        name: "Default Library",
        kind: "local",
        is_default: true,
        media_path: Setting.media_path,
        owner_id: first_admin_id,
        scan_state: "idle"
      )
    end

    # Associate every row that has no library yet with the Default_Library. The
    # existing global uniqueness guarantees mean there are no (library_id, *)
    # collisions when everything collapses into the one default library.
    BACKFILLED_TABLES.each do |table|
      execute("UPDATE #{table} SET library_id = #{default_library.id} WHERE library_id IS NULL")
    end

    # Every song/album/artist now belongs to exactly one library, so the
    # association can be made mandatory (Req 2.2).
    BACKFILLED_TABLES.each do |table|
      change_column_null table, :library_id, false
    end
  end

  def down
    BACKFILLED_TABLES.each do |table|
      change_column_null table, :library_id, true
    end

    default_library = MigrationLibrary.find_by(is_default: true)
    return unless default_library

    BACKFILLED_TABLES.each do |table|
      execute("UPDATE #{table} SET library_id = NULL WHERE library_id = #{default_library.id}")
    end

    default_library.delete
  end

  private

  def first_admin_id
    select_value("SELECT id FROM users WHERE #{quoted_is_admin_true} ORDER BY id ASC LIMIT 1")
  end

  def quoted_is_admin_true
    "is_admin = #{connection.quote(true)}"
  end
end
