# frozen_string_literal: true

require "test_helper"

# Task 8.4 — system/integration tests for the Home Continue_Listening surface
# added by the audiobook-resume-and-media-ui feature (Req 4.7, 10.1–10.4).
#
# The Home page (`HomeController#index` + `home/index.html.erb`) renders the
# `shared/_continue_listening` partial on every full-page response, so these
# flows exercise it over the same HTTP surface the browser uses. This matches
# the repo convention where browser-facing flows are verified as
# `ActionDispatch::IntegrationTest`s that render the application layout (see
# NavigationTabsTest, HomeControllerTest). A cookie session is established via
# `login` so the response renders HTML (not the JSON API surface).
#
# visitor1 owns and actively uses default_library, so its Songs are within the
# User's `authorized_library_ids` and qualify for the Continue_Listening_List
# (Req 4.4). Each in-progress record is seeded with a position at or above the
# Minimum_Resume_Position (10s) and `finished: false`, which is what the
# ContinueListeningQuery/Policy surfaces to Home.
class HomeContinueListeningTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:visitor1)
    # Start each flow with a clean slate so the surface state is deterministic.
    @user.playback_positions.delete_all
  end

  # Grab the continue-listening card for a given Song by its data-song-id hook.
  def continue_listening_card_selector(song)
    "div.c-card[data-song-id='#{song.id}']"
  end

  test "renders a Continue_Listening item with its Song name and Album name for an in-progress long track (Req 10.1, 10.2)" do
    # A Song at/above the Long_Track_Threshold is a Resumable_Track regardless of
    # content type (Req 1.2), so a plain music track lengthened past 1200s
    # qualifies once it has an in-progress Playback_Position_Record.
    song = songs(:mp3_sample)
    song.update!(duration: 1500.0)
    assert song.resumable?

    PlaybackPosition.create!(user: @user, song: song, position_seconds: 100.0, finished: false)

    login(@user)
    get root_url
    assert_response :success

    # The surface renders its heading (Req 10.1) and an item card carrying the
    # Song name, its Album name, and identifying detail (Req 10.2).
    assert_select "h1", text: I18n.t("label.continue_listening")
    assert_select continue_listening_card_selector(song) do
      assert_select "span", text: song.name
      assert_select "a[href=?]", album_path(song.album), text: song.album.name
      assert_select "span", text: song.artist.name
    end
  end

  test "renders audiobook enrichment context (author/publish-year) for an audiobook item with stored enrichment (Req 10.3)" do
    # An Audiobook Album (classified from its genre tag by ContentClassifier)
    # with stored Open Library enrichment. Songs on an Audiobook are Resumable
    # regardless of duration (Req 1.1); a long duration lets the record hold a
    # meaningful in-progress position (>= 10s) that is within [0, duration].
    album = albums(:album3)
    album.update!(
      genre: "Audiobook",
      enrichment: { "authors" => [ "Homer" ], "first_publish_year" => -800 }
    )
    assert album.audiobook?, "expected the album to classify as an audiobook"
    assert album.enriched?, "expected the album to report stored enrichment"

    song = songs(:ogg_sample)
    song.update!(duration: 3600.0)
    assert song.resumable?

    PlaybackPosition.create!(user: @user, song: song, position_seconds: 200.0, finished: false)

    login(@user)
    get root_url
    assert_response :success

    # The item mirrors the albums/show enrichment display: an audiobook badge
    # plus the author (and publish year) already stored for the Album (Req 10.3).
    assert_select continue_listening_card_selector(song) do
      assert_select "span.c-badge", text: I18n.t("label.audiobook")
      assert_select "span", text: "#{I18n.t('label.author')}: Homer"
      assert_select "span", text: "(-800)"
    end
  end

  test "renders the empty state without error when there are no in-progress tracks (Req 4.7, 10.4)" do
    # No Playback_Position_Records exist for the User (cleared in setup), so the
    # Continue_Listening_List is empty and the surface must render its empty
    # state message without error (Req 4.7, 10.4).
    assert_empty @user.playback_positions

    login(@user)
    get root_url
    assert_response :success

    # The heading still renders and the empty-state message is shown, with no
    # item cards present.
    assert_select "h1", text: I18n.t("label.continue_listening")
    assert_match I18n.t("label.no_continue_listening"), response.body
    assert_select "div.c-card[data-song-id]", count: 0
  end
end
