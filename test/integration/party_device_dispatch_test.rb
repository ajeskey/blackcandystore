# frozen_string_literal: true

require "test_helper"

# Integration coverage for Party Mode device dispatch (task 11.3; Req 6.1, 6.3).
# These exercise the boundary between the Rails PartyPlaybackDispatcher and the
# out-of-process Playback_Sidecar: the dispatcher fans the Shared_Playlist's
# current Song out to the Host's selected Output_Devices through the sidecar's
# `POST /play`. Because the sidecar owns the AirPlay/Chromecast wire protocols
# (design: the actual framing lives in the sidecar, never in Ruby), this is
# integration/contract coverage — not property-based.
#
# Rather than stubbing HTTP, we inject a fake `PlaybackSidecar::Client` that
# records the exact arguments the dispatcher hands to `play`. Those arguments
# map one-to-one onto the sidecar's `POST /play` body
# (`PlaybackSidecar::Client#play`), so asserting them asserts the wire shape:
# the selected device ids/descriptors, the resolved stream source/url, and a
# signed stream token that verifies via the sidecar-stream purpose
# (SidecarStreamAccess). The test also asserts the Shared_Playlist order is used
# by driving ProgramSequencer in MODE_PLAYLIST through the dispatcher.
class PartyDeviceDispatchTest < ActiveSupport::TestCase
  # A stand-in for PlaybackSidecar::Client that captures each `play` call's
  # keyword arguments (the JSON body the real client would POST to `/play`) so
  # the test can assert the dispatch shape without any network I/O.
  class FakeSidecarClient
    attr_reader :calls

    def initialize(response: { "status" => "playing" })
      @calls = []
      @response = response
    end

    def play(**kwargs)
      @calls << kwargs
      @response
    end

    def played?
      @calls.any?
    end

    def last_call
      @calls.last
    end
  end

  setup do
    OutputDevice.delete_all
    # visitor1 owns default_library and has it as their active library, so it is
    # authorized to share it (Req 4.7) and every fixture Song below is playable.
    @host = users(:visitor1)
    @library = libraries(:default_library)

    @session = PartySession.create!(
      user: @host,
      session_duration_kind: "perpetual",
      shared_library_ids: [ @library.id ]
    )
    @playlist = SharedPlaylist.create!(sessionable: @session)

    # Ordered Shared_Playlist: three local fixture Songs the Host added.
    @first_song = songs(:mp3_sample)
    @second_song = songs(:flac_sample)
    @third_song = songs(:ogg_sample)
    @playlist.entries.create!(song_id: @first_song.id, added_by_user: @host)
    @playlist.entries.create!(song_id: @second_song.id, added_by_user: @host)
    @playlist.entries.create!(song_id: @third_song.id, added_by_user: @host)

    @client = FakeSidecarClient.new
  end

  def airplay_device(identifier:, requires_password: false)
    OutputDevice.create!(
      identifier: identifier,
      name: identifier,
      protocol: "airplay",
      requires_password: requires_password,
      reachable_at: Time.current
    )
  end

  def chromecast_device(identifier:)
    OutputDevice.create!(
      identifier: identifier,
      name: identifier,
      protocol: "chromecast",
      requires_password: false,
      reachable_at: Time.current
    )
  end

  def dispatcher
    PartyPlaybackDispatcher.for_session(@session, client: @client, resolver: PathResolver.new)
  end

  # --- Req 6.1: selecting devices dispatches the current Song via POST /play --

  test "selecting output devices dispatches the current song to them via the sidecar (Req 6.1)" do
    living_room = airplay_device(identifier: "living-room")
    kitchen = chromecast_device(identifier: "kitchen")

    result = dispatcher.select_devices([ living_room.id, kitchen.id ], user: @host)

    assert result.ok?, "expected party dispatch to the selected devices to succeed"
    assert @client.played?, "expected the sidecar's POST /play to be invoked"

    body = @client.last_call
    # POST /play targets exactly the Host's selected Output_Devices (Req 6.1).
    assert_equal [ living_room.id, kitchen.id ].sort, body[:device_ids].sort
  end

  # --- POST /play shape: device descriptors + resolved stream + signed token --

  test "POST /play carries device descriptors, resolved local stream, and a scoped stream token (Req 6.1)" do
    living_room = airplay_device(identifier: "living-room")

    result = dispatcher.select_devices([ living_room.id ], user: @host)
    assert result.ok?

    body = @client.last_call

    # Device descriptors carry the protocol-level identifier the sidecar needs
    # to reach the real device, keyed back to the Rails id.
    descriptor = body[:devices].first
    assert_equal living_room.id, descriptor[:id]
    assert_equal "living-room", descriptor[:identifier]
    assert_equal "airplay", descriptor[:protocol]
    assert_equal false, descriptor[:requires_password]

    # Local fixture Songs resolve to the current-server stream path (Req 6.1).
    assert_equal PathResolver::STREAM_SOURCE_LOCAL, body[:stream_source]
    assert body[:stream_url].present?, "expected a resolved stream url"

    # The stream token verifies to exactly the dispatched Song under the
    # sidecar-stream purpose (SidecarStreamAccess), and to no other Song.
    verified = Song.find_signed(body[:stream_token], purpose: PlaybackController::SIDECAR_STREAM_PURPOSE)
    assert_equal @first_song.id, verified&.id
    assert_equal @first_song.id, body[:song_id] if body.key?(:song_id)
  end

  test "the dispatched song's signed token does not verify against a different song" do
    living_room = airplay_device(identifier: "living-room")

    assert dispatcher.select_devices([ living_room.id ], user: @host).ok?

    token = @client.last_call[:stream_token]
    verified = Song.find_signed(token, purpose: PlaybackController::SIDECAR_STREAM_PURPOSE)
    assert_equal @first_song.id, verified.id
    assert_not_equal @second_song.id, verified.id
  end

  # --- Req 6.3: playback follows the Shared_Playlist order (MODE_PLAYLIST) -----

  test "dispatch plays the shared playlist in its current order (Req 6.3)" do
    living_room = airplay_device(identifier: "living-room")
    @session.output_device_ids = [ living_room.id ]
    play = dispatcher

    # With no history the sequencer starts at the top of the ordered playlist.
    first = play.dispatch(user: @host)
    assert first.ok?
    assert_equal @first_song.id, first.song_id

    # After the first entry has played, MODE_PLAYLIST advances to the next entry.
    second = play.dispatch(history: [ @first_song.id ], user: @host)
    assert second.ok?
    assert_equal @second_song.id, second.song_id

    third = play.dispatch(history: [ @first_song.id, @second_song.id ], user: @host)
    assert third.ok?
    assert_equal @third_song.id, third.song_id

    # Each dispatch handed the corresponding Song's token to the sidecar, in
    # playlist order.
    dispatched_song_ids = @client.calls.map do |call|
      Song.find_signed(call[:stream_token], purpose: PlaybackController::SIDECAR_STREAM_PURPOSE).id
    end
    assert_equal [ @first_song.id, @second_song.id, @third_song.id ], dispatched_song_ids
  end

  test "shared playlist loops back to the first entry after the last has played (Req 6.3, 6.7)" do
    living_room = airplay_device(identifier: "living-room")
    @session.output_device_ids = [ living_room.id ]

    result = dispatcher.dispatch(
      history: [ @first_song.id, @second_song.id, @third_song.id ],
      user: @host
    )

    assert result.ok?
    # The last entry has played, so playback wraps to the first entry.
    assert_equal @first_song.id, result.song_id
  end

  # --- Boundary: nothing dispatched when there is no device or no song --------

  test "dispatch with no selected device sends no play command (Req 6.1 boundary)" do
    result = dispatcher.dispatch(user: @host)

    assert result.rejected?
    assert_equal :no_output_device, result.error
    assert_not @client.played?, "expected no POST /play without a selected device"
  end

  test "dispatch with an empty shared playlist sends no play command" do
    @playlist.entries.destroy_all
    living_room = airplay_device(identifier: "living-room")
    @session.output_device_ids = [ living_room.id ]

    result = dispatcher.dispatch(user: @host)

    assert result.rejected?
    assert_equal :no_current_song, result.error
    assert_not @client.played?
  end
end
