# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db", "migrate", "20260704174148_backfill_default_library.rb")

# Integration-style migration test (NOT property-based) for the Default_Library
# backfill data migration (Req 1.7, 8.8, 9.5).
#
# The migration is already applied and `library_id` is NOT NULL in the live
# schema, so this test first reconstructs the *pre-feature* state — content rows
# with a null `library_id` and no Default_Library — then runs the migration's
# own `up` logic and asserts the post-upgrade invariants:
#
#   * exactly one `is_default` library exists (Req 1.7)
#   * every song/album/artist is associated with that Default_Library (Req 1.7)
#   * existing cover-image attachments (and therefore their URLs) are untouched (Req 9.5)
#   * existing stream URLs remain the same current-server paths (Req 8.8)
#
# PostgreSQL DDL is transactional, so the temporary NOT NULL relaxation performed
# during setup is rolled back with the surrounding transactional test.
class DefaultLibraryBackfillMigrationTest < ActiveSupport::TestCase
  BACKFILLED_TABLES = %i[songs albums artists].freeze

  setup do
    @url_helpers = Rails.application.routes.url_helpers

    # Attach a cover image to a pre-existing album so we can prove the migration
    # leaves ActiveStorage `cover_image` attachments (and thus their URLs)
    # untouched (Req 9.5).
    @album = albums(:album1)
    @album.cover_image.attach(
      io: File.open(fixtures_file_path("cover_image.jpg")),
      filename: "cover_image.jpg",
      content_type: "image/jpeg"
    )
    @album.reload

    @song = songs(:mp3_sample)

    # Capture the pre-migration cover-image blob identity and the song's stream
    # path. Both resolved URLs are pure functions of these values (the cover URL
    # from the blob key/signed id, the stream URL from the song id), so if they
    # are unchanged by the migration the resolved URLs are unchanged too
    # (Req 8.8, 9.5).
    @cover_image_signed_id_before = @album.cover_image.blob.signed_id
    @cover_image_key_before = @album.cover_image.blob.key
    @stream_path_before = @url_helpers.new_stream_path(song_id: @song.id)

    # ---- Reduce the world to the pre-feature single-collection state ----
    # Pre-feature deployments had no library association on content and no
    # Default_Library. Relax the NOT NULL constraint the migration itself adds,
    # null out every association, then drop all libraries.
    connection = ActiveRecord::Base.connection
    BACKFILLED_TABLES.each do |table|
      connection.change_column_null(table, :library_id, true)
      connection.execute("UPDATE #{table} SET library_id = NULL")
    end
    [ Song, Album, Artist ].each(&:reset_column_information)
    Library.delete_all
  end

  test "backfill associates all content with a single Default_Library and preserves URLs" do
    # Pre-conditions: no library, all content unassociated.
    assert_equal 0, Library.count, "expected no libraries before the migration"
    [ Song, Album, Artist ].each do |klass|
      assert_operator klass.count, :>, 0, "expected #{klass.name} fixtures to exist"
      assert_equal klass.count, klass.where(library_id: nil).count,
        "expected every #{klass.name} row to be unassociated before the migration"
    end

    migration = BackfillDefaultLibrary.new
    migration.suppress_messages { migration.up }

    [ Song, Album, Artist ].each(&:reset_column_information)

    # Exactly one is_default library exists after the migration (Req 1.7).
    default_libraries = Library.where(is_default: true)
    assert_equal 1, default_libraries.count, "expected exactly one Default_Library"

    default_library = default_libraries.first
    assert default_library.local?, "expected the Default_Library to be a local library"
    assert_equal Setting.media_path, default_library.media_path

    # Every song/album/artist is now associated with that Default_Library
    # (Req 1.7).
    [ Song, Album, Artist ].each do |klass|
      assert_equal 0, klass.where.not(library_id: default_library.id).count,
        "expected every #{klass.name} row to belong to the Default_Library"
    end

    # Cover-image attachment is untouched: same blob and key => same URL (Req 9.5).
    @album.reload
    assert @album.cover_image.attached?, "expected the cover image to remain attached"
    assert_equal @cover_image_signed_id_before, @album.cover_image.blob.signed_id,
      "expected the cover-image blob (and thus its URL) to be unchanged"
    assert_equal @cover_image_key_before, @album.cover_image.blob.key,
      "expected the cover-image storage key (and thus its URL) to be unchanged"

    # Stream path is untouched: still the same current-server path (Req 8.8).
    @song.reload
    assert_equal @stream_path_before, @url_helpers.new_stream_path(song_id: @song.id),
      "expected the song's stream URL to be unchanged"
  end
end
