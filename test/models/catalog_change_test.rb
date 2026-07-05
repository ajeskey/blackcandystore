# frozen_string_literal: true

require "test_helper"

class CatalogChangeTest < ActiveSupport::TestCase
  # CatalogChange.changes_since serves the hosting-side change log to redeeming
  # servers: the ordered deltas after a Sync_Cursor plus the Catalog_Version to
  # adopt (Req 3.2, 3.4, 3.5, 3.6, 3.7).

  setup do
    @library = libraries(:default_library)
    @song = songs(:mp3_sample)     # id 1, album2 / artist1
    @album = albums(:album2)
    @artist = artists(:artist1)
  end

  def log(version:, item_type:, item_id:, change_type:)
    CatalogChange.create!(
      library: @library,
      version: version,
      item_type: item_type,
      item_id: item_id,
      change_type: change_type
    )
  end

  test "returns changes with version greater than the cursor ordered ascending (Req 3.2)" do
    log(version: 1, item_type: "song", item_id: @song.id, change_type: "upsert")
    log(version: 3, item_type: "song", item_id: 999, change_type: "deletion")
    log(version: 2, item_type: "album", item_id: @album.id, change_type: "upsert")
    @library.update!(catalog_version: 3)

    result = CatalogChange.changes_since(@library, 0)

    assert_equal 3, result.catalog_version
    assert_not result.full_sync_required
    assert_equal %w[song album song], result.changes.map(&:item_type)
    assert_equal [ "upsert", "upsert", "deletion" ], result.changes.map(&:change_type)
  end

  test "excludes changes at or before the cursor (Req 3.2)" do
    log(version: 1, item_type: "song", item_id: @song.id, change_type: "upsert")
    log(version: 2, item_type: "album", item_id: @album.id, change_type: "upsert")
    @library.update!(catalog_version: 2)

    result = CatalogChange.changes_since(@library, 1)

    assert_equal 1, result.changes.length
    assert_equal "album", result.changes.first.item_type
    assert_equal @album.id, result.changes.first.id
  end

  test "hydrates each upsert from its live row with associations (Req 3.4)" do
    log(version: 1, item_type: "song", item_id: @song.id, change_type: "upsert")
    @library.update!(catalog_version: 1)

    change = CatalogChange.changes_since(@library, 0).changes.first

    assert_equal "upsert", change.change_type
    assert_instance_of Song, change.record
    assert_equal @song.id, change.record.id
    assert_equal @song.name, change.record.name
    # Associations are carried on the hydrated record (Req 3.4, preserved for
    # the mirror to wire album/artist links).
    assert_equal @album.id, change.record.album_id
    assert_equal @artist.id, change.record.artist_id
  end

  test "passes deletions through by id and type with no hydrated record (Req 3.5)" do
    log(version: 1, item_type: "artist", item_id: 4242, change_type: "deletion")
    @library.update!(catalog_version: 1)

    change = CatalogChange.changes_since(@library, 0).changes.first

    assert_equal "deletion", change.change_type
    assert_equal "artist", change.item_type
    assert_equal 4242, change.id
    assert_nil change.record
  end

  test "returns an empty change set with the current version when cursor equals the catalog version (Req 3.6)" do
    log(version: 1, item_type: "song", item_id: @song.id, change_type: "upsert")
    @library.update!(catalog_version: 1)

    result = CatalogChange.changes_since(@library, 1)

    assert_empty result.changes
    assert_not result.full_sync_required
    assert_equal 1, result.catalog_version
  end

  test "returns an empty change set when cursor is greater than the catalog version (Req 3.6)" do
    @library.update!(catalog_version: 2)

    result = CatalogChange.changes_since(@library, 5)

    assert_empty result.changes
    assert_not result.full_sync_required
    assert_equal 2, result.catalog_version
  end

  test "signals full_sync_required with no partial set when cursor is below the retained log floor (Req 3.7)" do
    # The oldest retained change is version 5; a redeemer at cursor 0 needs the
    # compacted-away versions 1..4, so it must perform a full sync instead.
    log(version: 5, item_type: "song", item_id: @song.id, change_type: "upsert")
    log(version: 6, item_type: "album", item_id: @album.id, change_type: "upsert")
    @library.update!(catalog_version: 6)

    result = CatalogChange.changes_since(@library, 0)

    assert result.full_sync_required
    assert_empty result.changes
    assert_equal 6, result.catalog_version
  end

  test "serves incrementally when the cursor sits exactly at the retained log floor boundary (Req 3.7)" do
    # Oldest retained version is 5; a redeemer at cursor 4 needs version 5
    # onward, which is fully retained, so it is served incrementally.
    log(version: 5, item_type: "song", item_id: @song.id, change_type: "upsert")
    log(version: 6, item_type: "album", item_id: @album.id, change_type: "upsert")
    @library.update!(catalog_version: 6)

    result = CatalogChange.changes_since(@library, 4)

    assert_not result.full_sync_required
    assert_equal 2, result.changes.length
  end

  test "first-ever sync at cursor 0 with a fully retained log is served incrementally (Req 3.7)" do
    log(version: 1, item_type: "artist", item_id: @artist.id, change_type: "upsert")
    log(version: 2, item_type: "album", item_id: @album.id, change_type: "upsert")
    log(version: 3, item_type: "song", item_id: @song.id, change_type: "upsert")
    @library.update!(catalog_version: 3)

    result = CatalogChange.changes_since(@library, 0)

    assert_not result.full_sync_required
    assert_equal 3, result.changes.length
  end

  test "signals full_sync_required when the log is empty but the catalog has advanced (Req 3.7)" do
    @library.update!(catalog_version: 4)

    result = CatalogChange.changes_since(@library, 0)

    assert result.full_sync_required
    assert_empty result.changes
  end

  test "drops an upsert whose live row no longer exists so a later deletion converges" do
    log(version: 1, item_type: "song", item_id: 987_654, change_type: "upsert")
    @library.update!(catalog_version: 1)

    result = CatalogChange.changes_since(@library, 0)

    assert_empty result.changes
    assert_not result.full_sync_required
  end

  test "paginates results via pagy and exposes the pagy object" do
    # The app's configured pagy limit is 30 per page.
    45.times { |i| log(version: i + 1, item_type: "song", item_id: @song.id, change_type: "deletion") }
    @library.update!(catalog_version: 45)

    first_page = CatalogChange.changes_since(@library, 0, 1)
    assert_equal 30, first_page.changes.length
    assert_equal 45, first_page.pagy.count

    second_page = CatalogChange.changes_since(@library, 0, 2)
    assert_equal 15, second_page.changes.length
  end

  test "scopes the change log to the requested library" do
    other = libraries(:secondary_library)
    log(version: 1, item_type: "song", item_id: @song.id, change_type: "deletion")
    CatalogChange.create!(library: other, version: 1, item_type: "song", item_id: 5, change_type: "deletion")
    @library.update!(catalog_version: 1)
    other.update!(catalog_version: 1)

    result = CatalogChange.changes_since(@library, 0)

    assert_equal 1, result.changes.length
    assert_equal @song.id, result.changes.first.id
  end
end
