# frozen_string_literal: true

require "test_helper"

# Task 12.2 — Co-listen fan-out integration/smoke test.
#
# A Co_Listen_Session is the Radio + Party combination (Req 7): an always-on
# Shared_Stream driven by a collaborative Shared_Playlist, where each admitted
# participant listens on their OWN device rather than a shared Output_Device.
# This test pins down the two participant-facing behaviours task 12.2 calls out,
# using injected fakes so no real Broadcaster / ffmpeg is required:
#
#   * Per-participant connect from the current position (Req 7.4, 7.6). An
#     admitted participant tunes into the session's Stream_Endpoint with their
#     guest-derived Stream_Token (StreamTokenService.colisten_token_for) and is
#     served `audio/mpeg` from the Broadcaster's current-position fan-out; and
#     multiple participants each open that same session fan-out from the current
#     position — the "synchronized-ish" join every listener shares (Assumption
#     A2).
#
#   * Empty-playlist continuity → playback on first add (Req 7.9). While the
#     Shared_Playlist is empty the BroadcastSource yields a `continuity`
#     directive (keeping the stream open), and once a participant/host adds a
#     Song the next source resolves to exactly that Song. This is asserted both
#     on the pure BroadcastSource#next_source seam and end-to-end through
#     SessionLifecycleService#advance driving the Broadcaster's `POST /next`.
#
# The data-plane fan-out is an in-memory FakeStreamBroadcaster injected via
# `Broadcaster.stub(:client, ...)` (the same wiring as StreamEndpointTest), and
# the control-plane advance uses the shared FakeBroadcaster (test/support). The
# fixture Songs live in a local Library, so BroadcastSource resolves them to a
# real (same-origin) stream path without any additional stubbing.
#
# _Requirements: 7.4, 7.6, 7.9_
class CoListenFanOutTest < ActionDispatch::IntegrationTest
  # An in-memory stand-in for the Broadcaster fan-out/control client. It serves
  # the data-plane `listen` the Stream_Endpoint reverse-proxies (yielding
  # representative MP3 bytes as the current encode position) and the
  # control-plane `status` that feeds the connect-time Listener_Limit decision.
  # Every `listen` is recorded so a test can assert which broadcast id each
  # participant tuned into.
  class FakeStreamBroadcaster
    # Representative continuous-MP3 bytes: an ID3 header, an MP3 frame sync, and
    # some payload — enough for the client to receive `audio/mpeg`.
    AUDIO_FRAGMENTS = [ "ID3\x04\x00".b, "\xFF\xFB\x90\x64".b, "co-listen-audio-bytes".b ].freeze

    attr_reader :listen_calls, :status_calls

    def initialize(listeners: 0, fragments: AUDIO_FRAGMENTS)
      @listeners = listeners
      @fragments = fragments
      @listen_calls = []
      @status_calls = []
    end

    def status(broadcast_id)
      @status_calls << broadcast_id
      { "broadcast_id" => broadcast_id, "position" => 0, "listeners" => @listeners, "uptime" => 0 }
    end

    def listen(broadcast_id, &block)
      @listen_calls << broadcast_id
      @fragments.each { |fragment| block.call(fragment) }
    end
  end

  setup do
    # visitor1 owns default_library, so a session shared to it satisfies the
    # host-authorization subset check (Req 4.7) and its fixture Songs resolve to
    # a real local stream path.
    @owner = users(:visitor1)
    @library = libraries(:default_library)
  end

  # --- Req 7.4 / 7.6: per-participant connect from the current position -------

  test "an admitted participant connects to the co-listen stream and is served audio from the current position (Req 7.4)" do
    session = create_active_co_listen_session!
    guest = admit_guest!(session)
    token = StreamTokenService.colisten_token_for(guest)
    fake = FakeStreamBroadcaster.new(listeners: 0)

    with_broadcaster(fake) do
      get stream_co_listen_session_url(session, format: :mp3, token: token)
    end

    assert_response :success
    assert_equal "audio/mpeg", @response.get_header("Content-Type")
    # The connect opened the session's Broadcaster fan-out from the current
    # position, and its representative MP3 bytes reached the participant.
    assert_equal "co_listen_session:#{session.id}", fake.listen_calls.last
    assert_equal FakeStreamBroadcaster::AUDIO_FRAGMENTS.join, @response.body
  end

  test "multiple participants each open the same session fan-out from the current position (Req 7.4, 7.6)" do
    session = create_active_co_listen_session!
    guests = Array.new(3) { |index| admit_guest!(session, display_name: "Participant #{index}") }
    fake = FakeStreamBroadcaster.new(listeners: 0)

    guests.each do |guest|
      token = StreamTokenService.colisten_token_for(guest)

      with_broadcaster(fake) do
        get stream_co_listen_session_url(session, format: :mp3, token: token)
      end

      assert_response :success
      assert_equal "audio/mpeg", @response.get_header("Content-Type")
      assert_equal FakeStreamBroadcaster::AUDIO_FRAGMENTS.join, @response.body
    end

    # Every participant joined the SAME session broadcast from the current
    # position — one fan-out per participant, all keyed by the session id. This
    # is the shared-position join underpinning the "synchronized-ish" listen.
    assert_equal 3, fake.listen_calls.size
    assert_equal [ "co_listen_session:#{session.id}" ] * 3, fake.listen_calls
  end

  # A Co_Listen_Session Shared_Stream is never public: without a valid
  # guest-derived Stream_Token the connect is rejected and no fan-out is opened,
  # so audio is served per participant only (Req 7.4 companion, Req 11.8).
  test "a connect without a valid guest-derived stream token is rejected and opens no fan-out (Req 7.4)" do
    session = create_active_co_listen_session!
    fake = FakeStreamBroadcaster.new(listeners: 0)

    with_broadcaster(fake) do
      get stream_co_listen_session_url(session, format: :mp3)
    end

    assert_response :unauthorized
    assert_no_match(%r{audio/}, @response.media_type.to_s)
    assert_empty fake.listen_calls, "an unauthorized connect must not open a Broadcaster fan-out"
  end

  # --- Req 7.9: empty-playlist continuity → playback on first add -------------

  test "an empty shared playlist yields continuity, then resolves to the first added song (Req 7.9)" do
    session = create_active_co_listen_session!
    source = BroadcastSource.new

    # No Song has ever been added: the next source is a continuity directive
    # that keeps the Shared_Stream open rather than closing it (Req 7.9).
    empty = source.next_source(session)
    assert_equal BroadcastSource::SOURCE_CONTINUITY, empty[:type]

    # A participant/host adds the first Song → the next source is exactly that
    # Song, so playback begins with it (Req 7.9).
    song = songs(:mp3_sample)
    add_song!(session, song)

    after_add = source.next_source(session)
    assert_equal BroadcastSource::SOURCE_SONG, after_add[:type]
    assert_equal song.id, after_add[:song_id]
  end

  test "advancing the session drives the Broadcaster from continuity to the added song (Req 7.9)" do
    session = create_active_co_listen_session!
    broadcaster = FakeBroadcaster.new

    # While empty, advancing hands the Broadcaster a continuity source (the
    # stream stays open with Continuity_Audio).
    empty_result = SessionLifecycleService
      .new(session, broadcaster: broadcaster, source: BroadcastSource.new)
      .advance
    assert empty_result.ok?
    assert_equal BroadcastSource::SOURCE_CONTINUITY, broadcaster.advanced.last[:source][:type]

    # After the first Song is added, advancing hands the Broadcaster that Song —
    # the continuity → playback transition on the wire to the Broadcaster.
    song = songs(:flac_sample)
    add_song!(session, song)

    play_result = SessionLifecycleService
      .new(session, broadcaster: broadcaster, source: BroadcastSource.new)
      .advance
    assert play_result.ok?
    transition = broadcaster.advanced.last[:source]
    assert_equal BroadcastSource::SOURCE_SONG, transition[:type]
    assert_equal song.id, transition[:song_id]
  end

  private

  # An `active` Co_Listen_Session shared to the owner's default library. Its
  # Shared_Stream is deliverable (Req 9.6) so the Stream_Endpoint serves audio.
  def create_active_co_listen_session!(listener_limit: nil)
    CoListenSession.create!(
      user: @owner,
      state: :active,
      session_duration_kind: "perpetual",
      listener_limit: listener_limit,
      shared_library_ids: [ @library.id ]
    )
  end

  # Admit a participant through the real admission seam: generate the session's
  # Share_Link(s), then admit against the backing grant. Returns the persisted
  # Guest bound to a fresh Guest_Token (from which the co-listen Stream_Token is
  # derived).
  def admit_guest!(session, display_name: nil)
    share_link = ShareLinkService.generate(session).first
    admission = GuestAccessResolver.admit(
      session: session,
      grant: share_link.access_grant,
      display_name: display_name
    )
    assert admission.ok?, "expected guest admission to succeed, got #{admission.error.inspect}"
    admission.guest
  end

  # Append a Song to the session's Shared_Playlist (creating the playlist on the
  # first add), attributed to the host. Reloads the session so the has_one
  # association reflects the new playlist.
  def add_song!(session, song)
    playlist = session.shared_playlist || SharedPlaylist.create!(sessionable: session)
    playlist.entries.create!(song_id: song.id, added_by_user: @owner)
    session.reload
  end

  def with_broadcaster(fake)
    Broadcaster.stub(:client, fake) { yield }
  end
end
