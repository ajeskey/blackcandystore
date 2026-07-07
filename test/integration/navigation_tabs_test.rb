# frozen_string_literal: true

require "test_helper"

# Task 9.3 — system/integration tests for the Global_Navigation tabs added by the
# audiobook-resume-and-media-ui feature (Req 9).
#
# The nav bar (`app/views/shared/_nav_bar.html.erb`) is rendered by the main
# application layout on every full-page response, so these flows exercise it over
# the same HTTP surface the browser uses. This matches the repo convention:
# `test/system/` holds no tests here — every browser-facing flow is verified as an
# `ActionDispatch::IntegrationTest` that renders the layout (see e.g.
# KeyUiFlowsTest, SharingUiTest). A cookie session is established via `login` so
# the responses render HTML (not the JSON API surface).
#
# The three added tabs (Radio Stations, Party Sessions, Co-listen Sessions) are
# rendered alongside the existing Home and Library tabs (Req 9.1–9.3, 9.8). Each
# tab's active state is derived from the current controller through the pure
# `NavTabs.active?` seam, so the active tab tracks the section being viewed
# (Req 9.4–9.6) and no social tab is active elsewhere (Req 9.9). The tab hrefs
# point at the existing section index routes, which resolve to those sections'
# own controllers under their own authorization (Req 9.7).
class NavigationTabsTest < ActionDispatch::IntegrationTest
  setup do
    # visitor1 owns default_library, so the section index pages render for an
    # authorized account.
    @user = users(:visitor1)
  end

  # Collect the hrefs of the tab items currently marked `is-active`.
  def active_tab_hrefs
    css_select("li.c-tab__item.is-active a").map { |a| a["href"] }
  end

  # Collect the hrefs of every tab item in the nav bar.
  def all_tab_hrefs
    css_select("nav ul.c-tab li.c-tab__item a").map { |a| a["href"] }
  end

  test "the nav bar renders all five tabs with hrefs pointing at their sections (Req 9.1-9.3, 9.8)" do
    login(@user)
    get root_url
    assert_response :success

    # Home and Library remain (Req 9.8) alongside the three added social tabs
    # (Req 9.1, 9.2, 9.3). Each tab links to its section's path.
    hrefs = all_tab_hrefs
    assert_includes hrefs, root_path
    assert_includes hrefs, library_overview_path
    assert_includes hrefs, radio_stations_path
    assert_includes hrefs, party_sessions_path
    assert_includes hrefs, co_listen_sessions_path

    # Each added tab carries its localized label linking to the section index.
    assert_select "nav a[href=?]", radio_stations_path, text: I18n.t("label.radio_stations")
    assert_select "nav a[href=?]", party_sessions_path, text: I18n.t("label.party_sessions")
    assert_select "nav a[href=?]", co_listen_sessions_path, text: I18n.t("label.co_listen_sessions")
  end

  test "no social-listening tab is active while viewing Home (Req 9.9)" do
    login(@user)
    get root_url
    assert_response :success

    active = active_tab_hrefs
    assert_not_includes active, radio_stations_path
    assert_not_includes active, party_sessions_path
    assert_not_includes active, co_listen_sessions_path
    # Home is the active tab on the Home page.
    assert_includes active, root_path
  end

  test "the Radio Stations tab is the active social tab while viewing that section (Req 9.4)" do
    login(@user)
    get radio_stations_url
    assert_response :success

    assert_select "li.c-tab__item.is-active a[href=?]", radio_stations_path
    active = active_tab_hrefs
    assert_includes active, radio_stations_path
    assert_not_includes active, party_sessions_path
    assert_not_includes active, co_listen_sessions_path
  end

  test "the Party Sessions tab is the active social tab while viewing that section (Req 9.5)" do
    login(@user)
    get party_sessions_url
    assert_response :success

    assert_select "li.c-tab__item.is-active a[href=?]", party_sessions_path
    active = active_tab_hrefs
    assert_includes active, party_sessions_path
    assert_not_includes active, radio_stations_path
    assert_not_includes active, co_listen_sessions_path
  end

  test "the Co-listen Sessions tab is the active social tab while viewing that section (Req 9.6)" do
    login(@user)
    get co_listen_sessions_url
    assert_response :success

    assert_select "li.c-tab__item.is-active a[href=?]", co_listen_sessions_path
    active = active_tab_hrefs
    assert_includes active, co_listen_sessions_path
    assert_not_includes active, radio_stations_path
    assert_not_includes active, party_sessions_path
  end

  test "each social tab href resolves to its section under the section's own authorization (Req 9.7)" do
    login(@user)

    # The hrefs rendered in the nav bar are exactly the section index routes, and
    # following each one reaches that section's controller successfully for the
    # authorized account — the feature only links to the existing sections and
    # does not alter their authorization (A5).
    { radio_stations_path => "radio_stations",
      party_sessions_path => "party_sessions",
      co_listen_sessions_path => "co_listen_sessions" }.each do |path, controller|
      get path
      assert_response :success
      assert_equal controller, @controller.controller_name,
        "expected #{path} to resolve to the #{controller} controller"
    end
  end
end
