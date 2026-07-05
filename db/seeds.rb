# This file should contain all the record creation needed to seed the database with its default values.
# The data can then be loaded with the rails db:seed command (or created alongside the database with db:setup).
#
# Idempotent so it is safe to run on every boot (db:prepare seeds a newly
# created database, and `rails db:seed` may be run again on an existing one).

admin = User.find_or_create_by!(email: "admin@admin.com") do |user|
  user.password = "foobar"
  user.is_admin = true
end

# Ensure the pre-existing single-collection workflow keeps working on a fresh
# install. The Default_Library represents the collection backed by MEDIA_PATH
# (Req 1.7). On an UPGRADE it is created by the BackfillDefaultLibrary data
# migration, but a fresh install loads db/schema.rb directly and never runs that
# data migration — so create it here when it does not already exist. Without it
# a fresh server has no library to browse, and MEDIA_PATH scanning has nowhere
# to associate content.
unless Library.exists?(is_default: true)
  Library.create!(
    name: "Default Library",
    kind: :local,
    is_default: true,
    media_path: Setting.media_path,
    owner: admin
  )
end
