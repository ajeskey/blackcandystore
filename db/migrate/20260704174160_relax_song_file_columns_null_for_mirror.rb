class RelaxSongFileColumnsNullForMirror < ActiveRecord::Migration[8.1]
  # A Mirrored_Song in a kind: remote Library stores metadata only and carries
  # no local file: no `file_path` and no `md5_hash` (the mirror stores no audio
  # bytes, Req 1.4). The model already relaxes the *presence validations* for
  # these columns to local libraries only (they still hold for local content),
  # but the columns were created NOT NULL, which would reject a byte-less
  # mirrored row at the database level. Relax the NOT NULL constraints so a
  # Mirrored_Song can be materialized with these columns null while local songs
  # remain validated for presence by the model.
  #
  # This is additive and backward-compatible: dropping a NOT NULL constraint
  # never affects existing rows (all local songs already carry these values)
  # and never changes local-song validation, which is enforced in the model.
  def up
    change_column_null :songs, :file_path, true
    change_column_null :songs, :md5_hash, true
  end

  def down
    change_column_null :songs, :file_path, false
    change_column_null :songs, :md5_hash, false
  end
end
