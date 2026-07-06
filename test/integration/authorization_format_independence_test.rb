# frozen_string_literal: true

require "test_helper"

# Feature: radio-party-colisten, Property 28: Authorization is independent of response format
#
# *For any* request, the authorization outcome (permitted or rejected) is
# identical whether the request targets the HTML/Web_UI path or the JSON/API
# path for the equivalent action (Req 9.5).
#
# This integration test exercises a representative set of protected actions
# across the three controllers that respond to BOTH `format.html` and
# `format.json` — RadioStationsController, CoListenSessionsController, and
# PartySessionsController. For each action it drives the SAME request twice,
# authenticating through the Bearer path both times so that ONLY the requested
# response format differs, and asserts the allow/deny outcome matches across the
# two formats:
#
#   * an authorized actor (owner/Host or Admin) is allowed as HTML iff allowed
#     as JSON, and
#   * an unauthorized actor (a User who is neither owner/Host nor — for the
#     host-only actions — the Host) is denied as HTML iff denied as JSON.
#
# An authorization rejection surfaces as `BlackCandy::Forbidden`, which
# `ExceptionRescue` renders as HTTP 403 for both formats (a JSON error body and
# the plain-layout forbidden page), so 403 is the single, format-independent
# signal of a denied request.
class AuthorizationFormatIndependenceTest < ActionDispatch::IntegrationTest
  setup do
    # visitor1 owns default_library (see fixtures), so the resources it owns
    # select at least one authorized Song and share a real library. admin
    # exercises the Admin authority path; visitor2 is a full account that is
    # neither owner/Host nor Admin — the unauthorized actor.
    @owner = users(:visitor1)
    @admin = users(:admin)
    @other = users(:visitor2)
    @artist = artists(:artist1)
    @library = libraries(:default_library)
  end

  # --- factories: a fresh record per request so a state-changing action (start,
  # deactivate) in one call never leaks into the next comparison. ---

  def new_radio_station
    RadioStation.create!(
      user: @owner,
      name: "Station #{SecureRandom.hex(4)}",
      station_source_criteria: [ StationSourceCriterion.new(criterion_type: "artist", artist_id: @artist.id) ]
    )
  end

  def new_co_listen_session
    CoListenSession.create!(user: @owner, session_duration_kind: "perpetual", shared_library_ids: [ @library.id ])
  end

  def new_party_session
    PartySession.create!(user: @owner, session_duration_kind: "perpetual", shared_library_ids: [ @library.id ])
  end

  # Issue `method url` as `actor` in the requested `format` (:html or :json).
  # Both formats authenticate through the same Bearer token path, so the ONLY
  # difference between the two calls being compared is the response format.
  def request_as(method, url, actor:, format:, params: {})
    options = { headers: api_token_header(actor), params: params }
    options[:as] = :json if format == :json
    public_send(method, url, **options)
  end

  # An action is *denied* iff it is rejected with an authorization error, which
  # ExceptionRescue renders as 403 Forbidden for BOTH formats. Anything else
  # (2xx, or the HTML success path's 3xx redirect) is an *allow*.
  def denied?
    @response.forbidden?
  end

  # Run one protected action twice for `actor` — once as HTML, once as JSON —
  # and assert the authorization outcome is identical across formats (the
  # property). `expect_denied` additionally pins the expected allow/deny so the
  # test is meaningful: it would fail a controller that blindly allowed or denied
  # everything regardless of who is asking.
  def assert_outcome_independent_of_format(description, actor, expect_denied:, &action)
    action.call(actor, :html)
    html_denied = denied?

    action.call(actor, :json)
    json_denied = denied?

    assert_equal html_denied, json_denied,
      "#{description}: #{actor.email} was #{html_denied ? "denied" : "allowed"} as HTML " \
      "but #{json_denied ? "denied" : "allowed"} as JSON — authorization must not depend on response format"

    assert_equal expect_denied, html_denied,
      "#{description}: expected #{actor.email} to be #{expect_denied ? "denied" : "allowed"}, " \
      "but was #{html_denied ? "denied" : "allowed"}"
  end

  # Verify a protected action across a set of authorized and unauthorized actors.
  def verify_action(description, authorized:, unauthorized:, &action)
    authorized.each { |actor| assert_outcome_independent_of_format(description, actor, expect_denied: false, &action) }
    unauthorized.each { |actor| assert_outcome_independent_of_format(description, actor, expect_denied: true, &action) }
  end

  # --- RadioStation: mutation authority (owner/Admin) and lifecycle authority ---

  test "radio station update authorization is independent of response format (Req 9.5)" do
    verify_action("radio_station#update", authorized: [ @owner, @admin ], unauthorized: [ @other ]) do |actor, format|
      station = new_radio_station
      request_as :patch, radio_station_url(station),
        actor: actor, format: format,
        params: { radio_station: { name: "Renamed #{SecureRandom.hex(2)}" } }
    end
  end

  test "radio station start authorization is independent of response format (Req 9.5)" do
    verify_action("radio_station#start", authorized: [ @owner, @admin ], unauthorized: [ @other ]) do |actor, format|
      station = new_radio_station
      request_as :post, start_radio_station_url(station), actor: actor, format: format
    end
  end

  # --- CoListenSession: mutation authority (Host/Admin) and lifecycle authority ---

  test "co-listen session update authorization is independent of response format (Req 9.5)" do
    verify_action("co_listen_session#update", authorized: [ @owner, @admin ], unauthorized: [ @other ]) do |actor, format|
      session = new_co_listen_session
      request_as :patch, co_listen_session_url(session),
        actor: actor, format: format,
        params: { co_listen_session: { max_guests: 10 } }
    end
  end

  test "co-listen session deactivate authorization is independent of response format (Req 9.5)" do
    verify_action("co_listen_session#deactivate", authorized: [ @owner, @admin ], unauthorized: [ @other ]) do |actor, format|
      session = new_co_listen_session
      request_as :post, deactivate_co_listen_session_url(session), actor: actor, format: format
    end
  end

  # --- PartySession: mutation authority (Host/Admin) and host-ONLY authority ---

  test "party session update authorization is independent of response format (Req 9.5)" do
    verify_action("party_session#update", authorized: [ @owner, @admin ], unauthorized: [ @other ]) do |actor, format|
      session = new_party_session
      request_as :patch, party_session_url(session),
        actor: actor, format: format,
        params: { party_session: { max_guests: 8 } }
    end
  end

  # Transport control (stop/pause/skip) is host-ONLY: even an Admin who is not
  # the Host is rejected (Req 6.8, 7.10). This is a stricter authority rule than
  # the mutation gate above, so it independently confirms format-independence for
  # host-only authorization — the Host is allowed on both formats while both the
  # Admin and another User are denied on both formats.
  test "party session transport control authorization is independent of response format (Req 9.5)" do
    verify_action("party_session#pause", authorized: [ @owner ], unauthorized: [ @admin, @other ]) do |actor, format|
      session = new_party_session
      request_as :post, pause_party_session_url(session), actor: actor, format: format
    end
  end
end
