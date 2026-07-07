# frozen_string_literal: true

require "test_helper"

# Integration coverage for the client-agnostic Playback_Position API surface
# (task 4.8): Songs::PlaybackPositionsController (#show / #update) and
# ContinueListeningController (#show). These tests exercise the full request
# stack — routing, the Authentication concern, the OwnershipGuard before_action,
# per-user scoping, and the JSON/HTML rendering — rather than any single unit.
#
# They validate:
#   * JSON and HTML #show/#update succeed for an authenticated client under
#     IDENTICAL authorization across formats (Req 8.1, 8.2, 8.3)
#   * a cookie session AND a Bearer token each authorize a request, while a
#     request with no credentials is rejected with 401 (Req 6.1, 7.2, 7.6)
#   * cross-user isolation — User A can neither read nor modify User B's record,
#     and B's record is left unchanged (Req 7.3, 7.4)
#   * the OwnershipGuard rejection of an indeterminate owner (Req 7.7) — the
#     structural guarantee is observable here (a foreign record is invisible),
#     and the guard's rejection logic is unit-tested in
#     test/controllers/concerns/ownership_guard_test.rb
#   * continue-listening returns the client-agnostic `{ items: [...] }` shape
#     (Req 8.1, 8.2)
class PlaybackPositionApiTest < ActionDispatch::IntegrationTest
  setup do
    # visitor1 owns default_library (see fixtures), so their positions live in
    # an authorized library and surface in the Continue_Listening_List. visitor2
    # is a separate full account — the "other user" for the isolation checks.
    @user = users(:visitor1)
    @other = users(:visitor2)

    # A Resumable_Track: lengthen a fixture song past the Long_Track_Threshold
    # so it qualifies for a Playback_Position_Record regardless of content type.
    @song = songs(:mp3_sample)
    @song.update!(duration: 3600.0)
  end

  # ---------------------------------------------------------------------------
  # #show / #update succeed for an authenticated client; identical authorization
  # across JSON and HTML (Req 8.1, 8.2, 8.3)
  # ---------------------------------------------------------------------------

  test "JSON #show returns the client-agnostic representation for an authenticated user (Req 8.1, 8.2)" do
    position = @user.playback_positions.create!(song: @song, position_seconds: 613.0)

    get song_playback_position_url(@song), as: :json, headers: api_token_header(@user)

    assert_response :success
    body = @response.parsed_body
    assert_equal @song.id, body["song_id"]
    assert_in_delta 613.0, body["position_seconds"], 0.001
    assert_equal false, body["finished"]
    assert body["updated_at"].present?, "the client-agnostic shape must include updated_at"
    # The representation must not depend on server-rendered HTML (Req 8.2).
    assert_equal %w[song_id position_seconds finished updated_at].sort, body.keys.sort
    assert_equal position.id, @user.playback_positions.find_by(song_id: @song.id).id
  end

  test "JSON #show returns 404 when the authenticated user has no record for the song (Req 6.2)" do
    get song_playback_position_url(@song), as: :json, headers: api_token_header(@user)

    assert_response :not_found
  end

  test "JSON #update upserts the current user's record and echoes the stored representation (Req 2.4, 8.1)" do
    assert_difference -> { @user.playback_positions.count }, 1 do
      patch song_playback_position_url(@song),
        as: :json,
        headers: api_token_header(@user),
        params: { playback_position: { position_seconds: 600.0 } }
    end

    assert_response :success
    body = @response.parsed_body
    assert_equal @song.id, body["song_id"]
    assert_in_delta 600.0, body["position_seconds"], 0.001

    record = @user.playback_positions.find_by(song_id: @song.id)
    assert_in_delta 600.0, record.position_seconds, 0.001
  end

  test "HTML #show and #update succeed under the same authorization as JSON (Req 8.3)" do
    login(@user)

    # HTML #show with no record yet -> 404 (matches the JSON not-found outcome).
    get song_playback_position_url(@song)
    assert_response :not_found

    # HTML #update succeeds (head :ok) and persists the record for Current.user.
    patch song_playback_position_url(@song), params: { playback_position: { position_seconds: 120.0 } }
    assert_response :success
    assert_in_delta 120.0, @user.playback_positions.find_by(song_id: @song.id).position_seconds, 0.001

    # HTML #show now finds the record and returns success.
    get song_playback_position_url(@song)
    assert_response :success
  end

  # ---------------------------------------------------------------------------
  # Authentication: cookie session AND Bearer token each authorize; missing
  # credentials -> 401 (Req 6.1, 7.2, 7.6)
  # ---------------------------------------------------------------------------

  test "a cookie session authorizes a playback-position request (Req 7.6)" do
    @user.playback_positions.create!(song: @song, position_seconds: 42.0)
    login(@user)

    get song_playback_position_url(@song), as: :json

    assert_response :success
    assert_in_delta 42.0, @response.parsed_body["position_seconds"], 0.001
  end

  test "a Bearer token authorizes a playback-position request (Req 7.6)" do
    @user.playback_positions.create!(song: @song, position_seconds: 42.0)

    get song_playback_position_url(@song), as: :json, headers: api_token_header(@user)

    assert_response :success
    assert_in_delta 42.0, @response.parsed_body["position_seconds"], 0.001
  end

  test "a request with no credentials is rejected with 401 on read and write (Req 6.1, 7.2)" do
    get song_playback_position_url(@song), as: :json
    assert_response :unauthorized

    patch song_playback_position_url(@song),
      as: :json,
      params: { playback_position: { position_seconds: 5.0 } }
    assert_response :unauthorized
  end

  test "continue-listening is rejected with 401 without credentials (Req 6.1, 7.2)" do
    get continue_listening_url, as: :json

    assert_response :unauthorized
  end

  # ---------------------------------------------------------------------------
  # Cross-user isolation (Req 7.3, 7.4) — reads are scoped to
  # Current.user.playback_positions, so B's record is invisible to A and an A
  # write never touches B's record.
  # ---------------------------------------------------------------------------

  test "User A cannot read User B's record; the read is scoped to A's own records (Req 7.3, 7.4)" do
    # B (visitor1) has a stored position for the song.
    b_record = @user.playback_positions.create!(song: @song, position_seconds: 800.0)

    # A (visitor2) authenticates and asks for the same song's position. Because
    # the read is scoped to A's own playback_positions, B's record is invisible
    # and A simply has none -> 404. B's record is not leaked.
    get song_playback_position_url(@song), as: :json, headers: api_token_header(@other)
    assert_response :not_found

    b_record.reload
    assert_in_delta 800.0, b_record.position_seconds, 0.001, "B's record must be unchanged by A's read"
  end

  test "User A's write creates A's own record and leaves User B's record unchanged (Req 7.3, 7.4)" do
    b_record = @user.playback_positions.create!(song: @song, position_seconds: 800.0)

    # A (visitor2) writes a position for the same song. The upsert is scoped to
    # A's own playback_positions, so it creates a NEW record owned by A rather
    # than mutating B's.
    assert_difference -> { @other.playback_positions.count }, 1 do
      patch song_playback_position_url(@song),
        as: :json,
        headers: api_token_header(@other),
        params: { playback_position: { position_seconds: 15.0 } }
    end
    assert_response :success

    a_record = @other.playback_positions.find_by(song_id: @song.id)
    assert_in_delta 15.0, a_record.position_seconds, 0.001
    assert_not_equal b_record.id, a_record.id, "A and B must own distinct records for the same song"

    b_record.reload
    assert_in_delta 800.0, b_record.position_seconds, 0.001, "B's record must be unchanged by A's write"
    assert_equal @user.id, b_record.user_id
  end

  # ---------------------------------------------------------------------------
  # OwnershipGuard — indeterminate owner (Req 7.7)
  #
  # The guard's rejection of a record whose owner cannot be resolved (blank
  # user_id, dangling user_id, or an owner other than Current.user) is verified
  # directly in test/controllers/concerns/ownership_guard_test.rb, which raises
  # BlackCandy::Forbidden for each of those cases. Through the real controller
  # path a foreign-owned record can never enter Current.user.playback_positions,
  # so the observable end-to-end guarantee is that such a record is never read
  # or modified — asserted here.
  # ---------------------------------------------------------------------------

  test "the controller wires the OwnershipGuard so ownership is enforced defensively (Req 7.7)" do
    assert_includes Songs::PlaybackPositionsController.ancestors, OwnershipGuard,
      "the controller must include OwnershipGuard so a record with an indeterminate owner is rejected"

    # End-to-end: B's record is never exposed to A through the guarded path.
    @user.playback_positions.create!(song: @song, position_seconds: 500.0)
    get song_playback_position_url(@song), as: :json, headers: api_token_header(@other)
    assert_response :not_found
  end

  # ---------------------------------------------------------------------------
  # Continue-listening returns the client-agnostic { items: [...] } shape
  # (Req 8.1, 8.2)
  # ---------------------------------------------------------------------------

  test "continue-listening JSON returns the client-agnostic list shape for authenticated users (Req 8.1, 8.2)" do
    @user.playback_positions.create!(song: @song, position_seconds: 613.0, updated_at: 1.minute.ago)

    # A second resumable song so the list has more than one item.
    other_song = songs(:ogg_sample)
    other_song.update!(duration: 2400.0)
    @user.playback_positions.create!(song: other_song, position_seconds: 300.0, updated_at: Time.current)

    get continue_listening_url, as: :json, headers: api_token_header(@user)

    assert_response :success
    body = @response.parsed_body
    assert body.key?("items"), "the client-agnostic shape must wrap the list under `items`"
    assert_equal 2, body["items"].size

    # Most-recently-updated first (Req 4.2): other_song led with Time.current.
    first = body["items"].first
    assert_equal other_song.id, first["song_id"]

    # Each item carries the client-agnostic fields, independent of rendered HTML.
    %w[song_id song_name album_name album_enrichment position_seconds duration updated_at].each do |key|
      assert first.key?(key), "continue-listening item must include #{key}"
    end
    assert_equal other_song.name, first["song_name"]
    assert_equal other_song.album.name, first["album_name"]
    assert_in_delta 300.0, first["position_seconds"], 0.001
    assert_in_delta 2400.0, first["duration"], 0.001
  end

  test "continue-listening returns an empty list without error when there is nothing in progress (Req 4.7, 8.2)" do
    get continue_listening_url, as: :json, headers: api_token_header(@user)

    assert_response :success
    assert_equal [], @response.parsed_body["items"]
  end
end
