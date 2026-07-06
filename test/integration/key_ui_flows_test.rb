# frozen_string_literal: true

require "test_helper"

# Task 14.4 — system/integration tests for the two key Web_UI flows of the
# radio-party-colisten feature:
#
#   1. Station create + start — a logged-in User creates a Radio_Station through
#      the ERB/Turbo form (name + a source criterion) and starts it, then sees
#      the started Station_State reflected on the station page (Req 1.1, 10.1).
#   2. Guest join + add via Turbo — a Guest opens a Party_Session Share_Link, is
#      admitted (receiving a Guest_Token carried to the guest client), and adds a
#      shared-library Song to the Shared_Playlist through the Turbo-Stream
#      contribution surface the guest client drives (Req 5.1, 5.2).
#
# These are written as `ActionDispatch::IntegrationTest`s that exercise the UI
# flows over HTTP rather than as Capybara/cuprite browser system tests. That is
# a deliberate, convention-matching choice: `test/system/` holds no tests in
# this repo — every browser-facing flow (e.g. SharingUiTest, SettingsUiTest,
# GuestAdmissionFlowTest) is verified as an integration test over the same HTTP
# surface the browser uses. The guest "add" is JS-driven (a Stimulus controller
# posting to the contribution endpoint), so this test drives that endpoint
# directly in the Turbo-Stream format the guest client requests, which is
# reliable here (no JS driver required) and asserts exactly the server behavior
# the UI depends on.
#
# The start lifecycle performs Broadcaster I/O (task 9.3). No Broadcaster runs
# in the test environment, so the in-memory FakeBroadcaster is injected through
# the same `Broadcaster.stub(:client, ...)` seam the controller/stream tests use,
# letting the happy-path start transition succeed.
class KeyUiFlowsTest < ActionDispatch::IntegrationTest
  setup do
    # visitor1 owns default_library, so an artist-criterion station selects at
    # least one authorized Song (Req 1.4) and the party may share that library
    # (Req 4.7). Its Songs are the ones a Guest can add (Req 5.2, 5.3).
    @user = users(:visitor1)
    @artist = artists(:artist1)
    @library = libraries(:default_library)
    @song = songs(:mp3_sample) # belongs to default_library, a shared library
  end

  def with_broadcaster(fake = FakeBroadcaster.new)
    Broadcaster.stub(:client, fake) { yield }
  end

  def guest_bearer_header(token)
    { authorization: ActionController::HttpAuthentication::Token.encode_credentials(token) }
  end

  # --- Flow 1: Station create + start ---------------------------------------

  test "a user creates a radio station through the form and starts it, seeing the started state" do
    login(@user)

    # The configuration form renders for a signed-in User.
    get new_radio_station_url
    assert_response :success
    assert_select "form#turbo-radio-station-form"

    # Submitting the form (name + one artist source criterion) creates a
    # Radio_Station owned by that User and redirects to its page (Req 1.1, 1.2).
    assert_difference -> { RadioStation.count }, 1 do
      post radio_stations_url, params: {
        radio_station: {
          name: "Late Night Jazz",
          stream_visibility: "authenticated",
          criteria: [ { criterion_type: "artist", artist_id: @artist.id } ]
        }
      }
    end

    station = RadioStation.find_by!(name: "Late Night Jazz")
    assert_equal @user.id, station.user_id
    assert station.stopped?, "a freshly created station starts in the stopped state"
    assert_redirected_to radio_station_url(station)

    # Following the redirect, the station page shows the stopped state with a
    # Start control and no Stop control.
    follow_redirect!
    assert_response :success
    assert_select "form[action=?]", start_radio_station_path(station)
    assert_select "form[action=?]", stop_radio_station_path(station), count: 0

    # Starting the station transitions it to `started` (Req 10.1). The lifecycle
    # talks to the Broadcaster, so the fake is injected for the start request.
    with_broadcaster do
      post start_radio_station_url(station)
    end
    assert_redirected_to radio_station_url(station)
    assert station.reload.started?, "starting the station transitions it to started"

    # The reloaded station page now reflects the started state: a Stop control
    # is offered and the Start control is gone.
    follow_redirect!
    assert_response :success
    assert_select "form[action=?]", stop_radio_station_path(station)
    assert_select "form[action=?]", start_radio_station_path(station), count: 0
  end

  # --- Flow 2: Guest join + add via Turbo -----------------------------------

  test "a guest opens a share link, is admitted, and adds a song via Turbo" do
    # A Host sets up a Party_Session sharing default_library, its Shared_Playlist,
    # and a Share_Link a Guest can open (Req 4.1, 4.2).
    session = PartySession.create!(
      user: @user,
      session_duration_kind: "perpetual",
      shared_library_ids: [ @library.id ]
    )
    shared_playlist = SharedPlaylist.create!(sessionable: session)
    share_link = ShareLinkService.generate(session).first
    token = share_link.access_grant.token

    # The Guest submits the join form. Admission issues a Guest_Token carried to
    # the guest client via the flash exactly once (Req 5.1, 5.13).
    assert_difference -> { Guest.count }, 1 do
      post guest_admit_url(token: token), params: { display_name: "Robin" }
    end
    assert_response :redirect
    guest_token = flash[:guest_token]
    assert guest_token.present?, "admission issues a Guest_Token to the guest client"

    guest = Guest.find_by_token(guest_token)
    assert_equal session, guest.sessionable

    # The guest client adds a shared-library Song to the Shared_Playlist through
    # the Turbo-Stream contribution surface, authenticating with the non-cookie
    # Bearer Guest_Token (Req 5.2, 9.2). The response is a Turbo Stream and the
    # entry is appended and attributed to the adding Guest (Req 5.12).
    assert_difference -> { shared_playlist.entries.count }, 1 do
      post shared_playlist_shared_playlist_entries_url(shared_playlist),
        params: { song_id: @song.id },
        headers: guest_bearer_header(guest_token).merge("Accept" => "text/vnd.turbo-stream.html")
    end

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", @response.media_type
    assert_select "turbo-stream"

    entry = shared_playlist.entries.reload.last
    assert_equal @song.id, entry.song_id
    assert_equal guest.id, entry.added_by_guest_id
    assert_equal "Robin", entry.guest_display_name
  end
end
