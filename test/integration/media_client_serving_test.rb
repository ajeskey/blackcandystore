# frozen_string_literal: true

require "test_helper"

# Integration / smoke tests for serving the library to external Media_Clients
# over the legacy DAAP (iTunes) and RSP (Roku) protocols
# (multi-server-library-sharing, task 29.2, Req 15.1–15.7).
#
# These are NOT property-based tests (the authorized-content SELECTION logic is
# covered by Property 22). They exercise the full connect -> serve flow
# end-to-end at the Rails service BOUNDARY (MediaClientService / DAAPService /
# RSPService) and complement — rather than duplicate — the shared unit tests in
# test/models/media_client_service_test.rb by framing each scenario as an
# end-to-end client session:
#
#   * connect -> browse authorized library content once enabled+authenticated
#     (Req 15.1 DAAP, Req 15.2 RSP)
#   * a disabled service refuses the connection and serves NO content, asserted
#     independently for the DAAP and RSP flags (Req 15.3, 15.4, 15.5)
#   * a valid account authenticates and is served (Req 15.6)
#   * a failed auth (unknown account / wrong password) is refused with an
#     authentication error and serves NO content (Req 15.7)
#   * SMOKE: the wire-protocol Adapter seam is explicitly not-implemented on the
#     Rails side, documenting the external-daemon boundary.
#
# OUT OF SCOPE (documented, deliberately NOT tested here): conformance against a
# REAL iTunes DAAP client or a REAL Roku RSP client, and the actual DAAP/RSP
# binary/HTTP wire framing. Those have no maintained pure-Ruby server and are
# served by a fronted/embedded external daemon (an OwnTone/forked-daapd style
# component). No such client or daemon exists in this environment, so real-client
# conformance would require that external harness. The `Adapter` smoke test below
# pins that boundary so it stays external and cannot silently leak into Rails.
class MediaClientServingTest < ActiveSupport::TestCase
  # Each row is one Media_Client protocol flow: the concrete service class and
  # the Setting flag that independently enables/disables it (Req 15.3). Running
  # every scenario across BOTH rows proves DAAP (Req 15.1) and RSP (Req 15.2)
  # behave identically at this boundary and that their flags are independent.
  SERVICES = [
    { protocol: "DAAP", service_class: DAAPService, enable_flag: :enable_daap },
    { protocol: "RSP", service_class: RSPService, enable_flag: :enable_rsp }
  ].freeze

  VALID_PASSWORD = "foobar"

  setup do
    # visitor1 owns the Default_Library, which holds every fixture Song, Album,
    # and Artist — a real account authorized to real local content.
    @owner = users(:visitor1)
    @default_library = libraries(:default_library)
    # Start every flow from a clean slate: both services disabled.
    SERVICES.each { |svc| Setting.update(svc[:enable_flag] => false) }
  end

  # --- connect -> browse authorized content (Req 15.1 DAAP, 15.2 RSP) --------

  SERVICES.each do |svc|
    protocol = svc[:protocol]
    service_class = svc[:service_class]
    enable_flag = svc[:enable_flag]

    test "#{protocol}: an enabled service lets an authenticated client connect and browse its authorized library" do
      Setting.update(enable_flag => true)

      # End-to-end: the Media_Client presents credentials and connects.
      service = service_class.connect(email: @owner.email, password: VALID_PASSWORD)

      assert_instance_of service_class, service
      assert_equal @owner, service.user

      # ...and then browses songs / albums / artists, receiving exactly the
      # account's authorized local content.
      expected_songs = Song.where(library_id: @default_library.id).order(:id).to_a
      expected_albums = Album.where(library_id: @default_library.id).order(:id).to_a
      expected_artists = Artist.where(library_id: @default_library.id).order(:id).to_a

      # Guard against a vacuous pass: the account genuinely has content.
      assert_not_empty expected_songs
      assert_not_empty expected_albums
      assert_not_empty expected_artists

      assert_equal expected_songs, service.songs.order(:id).to_a
      assert_equal expected_albums, service.albums.order(:id).to_a
      assert_equal expected_artists, service.artists.order(:id).to_a
    end

    # --- disabled service refuses + serves nothing (Req 15.4 DAAP, 15.5 RSP) --

    test "#{protocol}: a disabled service refuses the connection and serves no content" do
      # Flag left disabled by setup.
      assert_not service_class.enabled?

      error = assert_raises(MediaClientService::Disabled) do
        service_class.connect(email: @owner.email, password: VALID_PASSWORD)
      end
      assert_match(/disabled/, error.message)

      # Even a directly-bound instance serves nothing while disabled — no browse
      # path can leak content when the service is off.
      bound = service_class.new(@owner)
      assert_empty bound.songs
      assert_empty bound.albums
      assert_empty bound.artists
    end

    # --- valid auth succeeds (Req 15.6) ---------------------------------------

    test "#{protocol}: a valid account authenticates successfully before any content is served" do
      Setting.update(enable_flag => true)

      assert_equal @owner, service_class.authenticate(email: @owner.email, password: VALID_PASSWORD)

      service = service_class.connect(email: @owner.email, password: VALID_PASSWORD)
      assert_equal @owner, service.user
    end

    # --- failed auth refused + serves nothing (Req 15.7) ----------------------

    test "#{protocol}: an unknown account is refused with an authentication error and served no content" do
      Setting.update(enable_flag => true)

      assert_nil service_class.authenticate(email: "nobody@blackcandy.com", password: VALID_PASSWORD)
      assert_raises(MediaClientService::AuthenticationError) do
        service_class.connect(email: "nobody@blackcandy.com", password: VALID_PASSWORD)
      end
    end

    test "#{protocol}: a wrong password is refused with an authentication error and served no content" do
      Setting.update(enable_flag => true)

      assert_nil service_class.authenticate(email: @owner.email, password: "wrong-password")
      assert_raises(MediaClientService::AuthenticationError) do
        service_class.connect(email: @owner.email, password: "wrong-password")
      end
    end
  end

  # --- independent enable flags (Req 15.3) -----------------------------------

  test "DAAP and RSP enable flags are independent: enabling one does not enable the other" do
    Setting.update(enable_daap: true, enable_rsp: false)
    assert DAAPService.enabled?, "DAAP should be enabled"
    assert_not RSPService.enabled?, "RSP should remain disabled"

    # With RSP disabled, an RSP client is refused while DAAP still serves.
    assert_raises(MediaClientService::Disabled) do
      RSPService.connect(email: @owner.email, password: VALID_PASSWORD)
    end
    assert_not_empty DAAPService.connect(email: @owner.email, password: VALID_PASSWORD).songs

    Setting.update(enable_daap: false, enable_rsp: true)
    assert_not DAAPService.enabled?, "DAAP should now be disabled"
    assert RSPService.enabled?, "RSP should now be enabled"

    assert_raises(MediaClientService::Disabled) do
      DAAPService.connect(email: @owner.email, password: VALID_PASSWORD)
    end
    assert_not_empty RSPService.connect(email: @owner.email, password: VALID_PASSWORD).songs
  end

  # --- SMOKE: wire-protocol boundary is external -----------------------------

  test "SMOKE: the DAAP/RSP wire-protocol Adapter seam is not implemented on the Rails side" do
    # Documents the external-daemon boundary: Rails owns enablement, auth, and
    # authorized-content selection, but the actual protocol framing is served by
    # an external media server. The seam must stay explicitly not-implemented so
    # it cannot silently absorb wire-protocol responsibilities in Rails.
    Setting.update(enable_daap: true)
    service = DAAPService.connect(email: @owner.email, password: VALID_PASSWORD)
    adapter = MediaClientService::Adapter.new(service)

    error = assert_raises(NotImplementedError) { adapter.serve }
    assert_match(/external media server/, error.message)
  end
end
