# frozen_string_literal: true

require "test_helper"

# Property-based test for the audio-deliverability seam of the
# radio-party-colisten feature (design Property 8).
#
# Property 8 states: for any Radio_Station or Co_Listen_Session, its
# Stream_Endpoint URL exists regardless of state, but a request delivers audio
# iff the Radio_Station is `started` or the Co_Listen_Session is `active`;
# otherwise it returns a not-available response and no audio.
#
# The pure decision that governs this is `audio_deliverable?`, exposed by
# StationLifecycleService (true iff the station is `started`) and
# SessionLifecycleService (true iff the session is `active`). This test
# exercises that decision directly across every generated Station_State /
# Session_State — the Broadcaster and Stream_Endpoint controller are wired in
# later tasks, so here we validate the pure seam they will depend on.
#
# "The Stream_Endpoint URL exists regardless of state" is modeled at this seam
# by the record persisting (and thus being addressable) in every state: the
# station/session is a valid, persisted entity whether it is broadcasting or
# not, so its endpoint identity never blinks in and out with the state. What
# changes with state is solely whether `audio_deliverable?` says audio flows.
class AudioDeliverabilityPropertyTest < ActiveSupport::TestCase
  # A readable directory so freshly created local libraries pass media-path
  # validation; the fixtures directory always exists.
  MEDIA_PATH = Rails.root.join("test", "fixtures", "files").to_s

  STATION_STATES = %w[stopped started].freeze
  SESSION_STATES = %w[active ended].freeze

  setup do
    @seq = 0
  end

  # Feature: radio-party-colisten, Property 8: Audio is delivered iff the broadcast is running
  test "audio is deliverable iff the station is started or the session is active, while the endpoint exists in every state" do
    check_property(iterations: 100) do
      # Independently chosen states for a Radio_Station and a Co_Listen_Session
      # so both sides of the "iff", for both subject kinds, are exercised.
      [ choose(*STATION_STATES), choose(*SESSION_STATES) ]
    end.check do |(station_state, session_state)|
      owner = build_owner

      station = build_station(owner, station_state)
      session = build_session(owner, session_state)

      # The endpoint identity exists regardless of state: both subjects are
      # valid, persisted, addressable entities whether broadcasting or not.
      assert station.persisted?, "a station's endpoint must exist regardless of state"
      assert session.persisted?, "a session's endpoint must exist regardless of state"

      station_deliverable = StationLifecycleService.new(station).audio_deliverable?
      session_deliverable = SessionLifecycleService.new(session).audio_deliverable?

      # Audio is delivered iff the broadcast is running.
      assert_equal (station_state == "started"), station_deliverable,
        "station audio is deliverable iff it is started (state=#{station_state})"
      assert_equal (session_state == "active"), session_deliverable,
        "session audio is deliverable iff it is active (state=#{session_state})"

      # A non-running broadcast yields no audio (the not-available case): the
      # decision is strictly false, never a truthy/ambiguous value.
      assert_equal false, station_deliverable if station_state == "stopped"
      assert_equal false, session_deliverable if session_state == "ended"
    end
  end

  private

  def next_seq
    @seq += 1
  end

  # A fresh Host/owning User whose owned local libraries form its authorized set.
  def build_owner
    User.create!(email: "audio-owner-#{SecureRandom.uuid}@example.com", password: "foobar123")
  end

  # A persisted Radio_Station in `state`, backed by one authorized song selected
  # via an artist criterion so it passes the "selects at least one authorized
  # song" validation, then transitioned to the requested state.
  def build_station(owner, state)
    library = Library.create!(name: "AudioLib-#{next_seq}", kind: "local", media_path: MEDIA_PATH, owner: owner)
    n = next_seq
    artist = Artist.create!(name: "Artist-#{n}", library: library)
    album = Album.create!(name: "Album-#{n}", artist: artist, library: library, genre: "rock")
    Song.create!(
      name: "Song-#{n}",
      file_path: "/tmp/audio-song-#{n}.mp3",
      file_path_hash: "fph-#{n}",
      md5_hash: "md5-#{n}",
      library: library,
      album: album,
      artist: artist
    )

    station = RadioStation.new(user: owner, name: "Station-#{next_seq}", state: state)
    station.station_source_criteria.build(criterion_type: "artist", artist_id: artist.id)
    station.save!
    station
  end

  # A persisted Co_Listen_Session in `state` (perpetual, no shared libraries, so
  # the only variable is the state under test).
  def build_session(owner, state)
    CoListenSession.create!(user: owner, state: state)
  end
end
