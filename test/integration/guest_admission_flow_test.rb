# frozen_string_literal: true

require "test_helper"

# End-to-end happy path for Guest admission and Shared_Playlist contribution
# (task 8.9): a Host generates a Share_Link, a would-be Guest previews the join
# page, POSTs to be admitted (receiving a Guest_Token), and then uses that
# non-cookie Bearer Guest_Token to add a Song to the session's Shared_Playlist
# (Req 4.2, 5.1, 5.2, 5.13, 9.2). Exercised over the co-listen session; the
# admission surface is shared with party sessions.
class GuestAdmissionFlowTest < ActionDispatch::IntegrationTest
  setup do
    @host = users(:visitor1)
    @library = libraries(:default_library)
    @song = songs(:mp3_sample) # belongs to default_library (a shared library)

    @session = CoListenSession.create!(
      user: @host,
      session_duration_kind: "perpetual",
      shared_library_ids: [ @library.id ]
    )
    @shared_playlist = SharedPlaylist.create!(sessionable: @session)
  end

  def guest_bearer_header(token)
    { authorization: ActionController::HttpAuthentication::Token.encode_credentials(token) }
  end

  test "host generates a share link whose token opens the join page (Req 4.2, 5.1)" do
    share_link = ShareLinkService.generate(@session).first
    token = share_link.access_grant.token

    get guest_join_url(token: token), as: :json

    assert_response :ok
    assert @response.parsed_body["joinable"]
    assert_equal @session.id, @response.parsed_body.dig("session", "id")
    assert_equal "co_listen_session", @response.parsed_body.dig("session", "type")
  end

  test "opening a share link admits a guest and issues a bound Guest_Token (Req 5.1, 5.13)" do
    share_link = ShareLinkService.generate(@session).first
    token = share_link.access_grant.token

    assert_difference -> { Guest.count }, 1 do
      post guest_admit_url(token: token), params: { display_name: "Robin" }, as: :json
    end

    assert_response :created
    body = @response.parsed_body
    guest_token = body["guest_token"]
    assert guest_token.present?
    assert_equal "Robin", body.dig("guest", "display_name")
    assert_equal @shared_playlist.id, body.dig("session", "shared_playlist_id")

    # The issued Guest_Token resolves back to exactly the admitted Guest.
    guest = Guest.find(body.dig("guest", "id"))
    assert_equal guest, Guest.find_by_token(guest_token)
    assert_equal @session, guest.sessionable
  end

  test "an admitted guest adds a shared-library song using its Guest_Token (Req 5.2, 5.12, 9.2)" do
    share_link = ShareLinkService.generate(@session).first
    post guest_admit_url(token: share_link.access_grant.token), params: { display_name: "Sam" }, as: :json
    guest_token = @response.parsed_body["guest_token"]

    assert_difference -> { @shared_playlist.entries.count }, 1 do
      post shared_playlist_shared_playlist_entries_url(@shared_playlist),
        params: { song_id: @song.id },
        as: :json,
        headers: guest_bearer_header(guest_token)
    end

    assert_response :created
    body = @response.parsed_body
    assert_equal @song.id, body["song_id"]
    # The entry is attributed to the adding Guest (Req 5.12).
    guest = Guest.find_by_token(guest_token)
    assert_equal guest.id, body["added_by_guest_id"]
    assert_equal "Sam", body["guest_display_name"]
  end
end
