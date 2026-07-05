# frozen_string_literal: true

require "test_helper"

# Integration / smoke test for the Changes_Since_API round trip
# (remote-library-mirror-sync, task 4.3).
#
# Unlike the Property 3 authorization test (which sweeps grant states), this
# exercises the *network* shape of the endpoint a redeeming Server pulls from:
# `GET /federation/libraries/:library_id/changes` served by
# `Federation::ChangesController`. Requests hit the real HTTP path with an
# Access_Grant token presented as a Bearer credential, exactly as a remote
# redeeming Server would call it, and we assert against the Cross-Server HTTP
# API Contract:
#
#   * paged change-response shape  { catalog_version, full_sync_required, changes }
#     - upserts carry hosting-side id, type, metadata, and associations (Req 3.4)
#     - deletions carry only hosting-side id and type (Req 3.5)
#     - the page is bounded and carries pagination headers (Req 3.2)
#   * empty set at/beyond the current version                            (Req 3.6)
#   * 403 rejection for an unauthorized / expired / revoked / wrong-library
#     grant, returning no changes                                        (Req 3.3)
#
# This is NOT a property-based test — it is an example/smoke test of the
# cross-server request/response and authorization behavior.
class ChangesSinceApiTest < ActionDispatch::IntegrationTest
  setup do
    @library = libraries(:default_library)
    @token = "changes-since-token-abc123"
    @grant = AccessGrant.create!(
      library: @library,
      token: @token,
      expires_at: 1.day.from_now
    )
  end

  def bearer(token = @token)
    { authorization: "Bearer #{token}" }
  end

  # --- paged change-response shape (Req 3.2, 3.4, 3.5) -----------------------

  test "returns the change-response envelope with upsert metadata/associations and deletion id/type" do
    song = songs(:mp3_sample)
    album = albums(:album1)
    artist = artists(:artist1)

    record_change(version: 1, item_type: "song", item_id: song.id, change_type: "upsert")
    record_change(version: 2, item_type: "album", item_id: album.id, change_type: "upsert")
    record_change(version: 3, item_type: "artist", item_id: artist.id, change_type: "upsert")
    # A deletion whose live row is gone is fully described by id + type (Req 3.5).
    deleted_song_id = 987_654
    record_change(version: 4, item_type: "song", item_id: deleted_song_id, change_type: "deletion")
    @library.update!(catalog_version: 4)

    get federation_library_changes_url(library_id: @library.id), headers: bearer, as: :json

    assert_response :success
    body = @response.parsed_body

    # Envelope (Req 3.2).
    assert_equal 4, body["catalog_version"]
    assert_equal false, body["full_sync_required"]
    assert_kind_of Array, body["changes"]
    assert_equal 4, body["changes"].size

    changes = body["changes"]

    # Returned in non-decreasing version order (the seed order above).
    assert_equal %w[upsert upsert upsert deletion], changes.map { |c| c["change_type"] }
    assert_equal %w[song album artist song], changes.map { |c| c["item_type"] }

    # Song upsert carries hosting-side id, metadata, and associations (Req 3.4).
    song_change = changes[0]
    assert_equal song.id, song_change["id"]
    assert_equal song.name, song_change["name"]
    assert_equal song.duration, song_change["duration"]
    assert_equal song.album_id, song_change["album_id"]
    assert_equal song.artist_id, song_change["artist_id"]
    assert_equal song.album.name, song_change["album_name"]
    assert_equal song.artist.name, song_change["artist_name"]

    # Album upsert carries its metadata and artist association (Req 3.4).
    album_change = changes[1]
    assert_equal album.id, album_change["id"]
    assert_equal album.name, album_change["name"]
    assert_equal album.year, album_change["year"]
    assert_equal album.artist_id, album_change["artist_id"]
    assert_equal album.artist.name, album_change["artist_name"]

    # Artist upsert carries its metadata (Req 3.4).
    artist_change = changes[2]
    assert_equal artist.id, artist_change["id"]
    assert_equal artist.name, artist_change["name"]

    # Deletion carries only hosting-side id + type, no metadata (Req 3.5).
    deletion_change = changes[3]
    assert_equal deleted_song_id, deletion_change["id"]
    assert_equal "deletion", deletion_change["change_type"]
    assert_equal "song", deletion_change["item_type"]
    refute deletion_change.key?("name"), "a deletion change must not carry item metadata"
    refute deletion_change.key?("duration"), "a deletion change must not carry item metadata"
  end

  test "paginates the change set and carries pagination headers" do
    song = songs(:mp3_sample)
    page_limit = Pagy::DEFAULT[:limit]
    total = page_limit + 1

    # Seed one page worth plus one extra upsert (all resolving to a live row) so
    # the delta spans two pages.
    (1..total).each do |version|
      record_change(version: version, item_type: "song", item_id: song.id, change_type: "upsert")
    end
    @library.update!(catalog_version: total)

    # Page 1: a full page, bounded by the page limit.
    get federation_library_changes_url(library_id: @library.id, page: 1), headers: bearer, as: :json
    assert_response :success
    first_page = @response.parsed_body
    assert_equal page_limit, first_page["changes"].size
    assert_equal total, first_page["catalog_version"]

    pagination_header = @response.headers.keys.find do |key|
      %w[current-page page-items total-count total-pages].include?(key.downcase)
    end
    assert pagination_header, "expected the response to carry pagination headers"

    # Page 2: the remaining change.
    get federation_library_changes_url(library_id: @library.id, page: 2), headers: bearer, as: :json
    assert_response :success
    second_page = @response.parsed_body
    assert_equal total - page_limit, second_page["changes"].size
  end

  # --- empty set at/beyond the current version (Req 3.6) ---------------------

  test "returns an empty change set with the current version when the cursor equals the current version" do
    song = songs(:mp3_sample)
    record_change(version: 1, item_type: "song", item_id: song.id, change_type: "upsert")
    @library.update!(catalog_version: 3)

    get federation_library_changes_url(library_id: @library.id, cursor: 3), headers: bearer, as: :json

    assert_response :success
    body = @response.parsed_body
    assert_equal 3, body["catalog_version"]
    assert_equal false, body["full_sync_required"]
    assert_empty body["changes"]
  end

  test "returns an empty change set when the cursor is beyond the current version" do
    song = songs(:mp3_sample)
    record_change(version: 1, item_type: "song", item_id: song.id, change_type: "upsert")
    @library.update!(catalog_version: 3)

    get federation_library_changes_url(library_id: @library.id, cursor: 99), headers: bearer, as: :json

    assert_response :success
    body = @response.parsed_body
    assert_equal 3, body["catalog_version"]
    assert_empty body["changes"]
  end

  # --- 403 rejection returns no changes (Req 3.3) ----------------------------

  test "rejects an unknown token with 403 and returns no changes" do
    @library.update!(catalog_version: 1)

    get federation_library_changes_url(library_id: @library.id), headers: bearer("not-a-real-token"), as: :json

    assert_response :forbidden
    refute_includes @response.body.to_s, "\"changes\""
  end

  test "rejects an expired grant with 403" do
    @grant.update!(expires_at: 1.day.ago)

    get federation_library_changes_url(library_id: @library.id), headers: bearer, as: :json

    assert_response :forbidden
    refute_includes @response.body.to_s, "\"changes\""
  end

  test "rejects a revoked grant with 403" do
    @grant.update!(status: :revoked)

    get federation_library_changes_url(library_id: @library.id), headers: bearer, as: :json

    assert_response :forbidden
    refute_includes @response.body.to_s, "\"changes\""
  end

  test "rejects a grant that references a different library with 403" do
    other_library = libraries(:secondary_library)

    # The grant is valid, but it authorizes @library, not the one requested.
    get federation_library_changes_url(library_id: other_library.id), headers: bearer, as: :json

    assert_response :forbidden
    refute_includes @response.body.to_s, "\"changes\""
  end

  test "rejects a request with no token at all with 403" do
    get federation_library_changes_url(library_id: @library.id), as: :json

    assert_response :forbidden
    refute_includes @response.body.to_s, "\"changes\""
  end

  private

  # Append one hosting-side Catalog_Change row for the local library under test.
  def record_change(version:, item_type:, item_id:, change_type:)
    CatalogChange.create!(
      library: @library,
      version: version,
      item_type: item_type,
      item_id: item_id,
      change_type: change_type
    )
  end
end
