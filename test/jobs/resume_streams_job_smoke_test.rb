# frozen_string_literal: true

require "test_helper"

# Smoke test for the server-restart resume path of the radio-party-colisten
# feature (task 9.5, Broadcaster integration/smoke coverage).
#
# The pure resume DECISION — which persisted Radio_Stations and
# Co_Listen_Sessions are eligible to resume — is covered exhaustively by
# ResumeStreamsPropertyTest (Property 26). This smoke test covers the
# complementary SIDE-EFFECTING wiring (task 9.3): that ResumeStreamsJob#perform
# actually drives the Broadcaster control client's `start_broadcast` once per
# eligible broadcast, with the stable Broadcaster-facing id and kind, and never
# for a stopped/ended/expired one.
#
# The Broadcaster is the injected in-memory FakeBroadcaster (test/support), so
# no out-of-process service is required; because the broadcaster holds no
# authoritative state, "restart resume re-establishes broadcasts" is exactly
# this re-issuing of `start_broadcast` from Rails' persisted state (Req 10.4,
# 10.10, 12.4).
#
# _Requirements: 10.4, 10.10, 12.4 (Broadcaster re-establishment wiring)_
class ResumeStreamsJobSmokeTest < ActiveSupport::TestCase
  # A readable directory so freshly created local libraries pass media-path
  # validation; the fixtures directory always exists.
  MEDIA_PATH = Rails.root.join("test", "fixtures", "files").to_s

  # A BroadcastSource that reuses the real (pure) id/kind derivation but returns
  # a fixed continuity directive for `next_source`, so the smoke test stays
  # hermetic (no path/token/filesystem resolution) while still asserting the
  # exact Broadcaster-facing broadcast ids the resume job hands over.
  class StubSource < BroadcastSource
    def next_source(_subject, history: [])
      { type: BroadcastSource::SOURCE_CONTINUITY }
    end
  end

  setup do
    @seq = 0
    @fixture_library_ids = [ libraries(:default_library).id, libraries(:secondary_library).id ]
    @now = Time.current
    @source = BroadcastSource.new
  end

  test "resume re-establishes exactly the started stations and active non-expired sessions on the Broadcaster" do
    reset_dataset!
    Setting.update(max_concurrent_streams: nil)

    started_a = build_station(state: :started, created_at: @now - 3.minutes)
    started_b = build_station(state: :started, created_at: @now - 2.minutes)
    stopped = build_station(state: :stopped, created_at: @now - 4.minutes)
    active = build_session(state: :active, created_at: @now - 1.minute) # perpetual, live
    ended = build_session(state: :ended, created_at: @now - 5.minutes)
    expired = build_session(
      state: :active, kind: "hours", value: 1, created_at: @now - 2.hours
    )

    broadcaster = FakeBroadcaster.new
    ResumeStreamsJob.new.perform(now: @now, broadcaster: broadcaster, source: StubSource.new)

    started_ids = broadcaster.started.map { |call| call[:broadcast_id] }

    # Exactly the eligible broadcasts, each re-established once, in the job's
    # documented oldest-first order.
    assert_equal(
      [ started_a, started_b, active ].map { |b| @source.identifier(b) },
      started_ids
    )

    # The broadcast flavor is carried through for each re-established broadcast.
    kinds = broadcaster.started.map { |call| [ call[:broadcast_id], call[:kind] ] }.to_h
    assert_equal BroadcastSource::KIND_RADIO, kinds[@source.identifier(started_a)]
    assert_equal BroadcastSource::KIND_RADIO, kinds[@source.identifier(started_b)]
    assert_equal BroadcastSource::KIND_CO_LISTEN, kinds[@source.identifier(active)]

    # Nothing stopped, ended, or expired is ever re-established.
    [ stopped, ended, expired ].each do |subject|
      assert_not_includes started_ids, @source.identifier(subject),
        "a stopped/ended/expired broadcast must never be re-established"
    end
  end

  test "resume honors the concurrency cap, re-establishing only the oldest eligible broadcasts" do
    reset_dataset!
    Setting.update(max_concurrent_streams: 1)

    oldest = build_station(state: :started, created_at: @now - 3.minutes)
    build_station(state: :started, created_at: @now - 2.minutes)
    build_session(state: :active, created_at: @now - 1.minute)

    broadcaster = FakeBroadcaster.new
    ResumeStreamsJob.new.perform(now: @now, broadcaster: broadcaster, source: StubSource.new)

    started_ids = broadcaster.started.map { |call| call[:broadcast_id] }
    assert_equal [ @source.identifier(oldest) ], started_ids,
      "the cap must limit resume to the oldest eligible broadcast"
  end

  test "resume tolerates an unavailable Broadcaster without raising" do
    reset_dataset!
    Setting.update(max_concurrent_streams: nil)
    build_station(state: :started, created_at: @now - 1.minute)

    unavailable = FakeBroadcaster.new(available: false)

    assert_nothing_raised do
      ResumeStreamsJob.new.perform(now: @now, broadcaster: unavailable, source: StubSource.new)
    end
    assert_empty unavailable.started,
      "an unreachable Broadcaster records no re-established broadcasts"
  end

  private

  def next_seq
    @seq += 1
  end

  # Wipe all feature records and every non-fixture library/content row so each
  # test observes only the broadcasts it builds.
  def reset_dataset!
    CoListenSession.delete_all
    StationSourceCriterion.delete_all
    StreamToken.delete_all
    RadioStation.delete_all
    Song.delete_all
    Album.delete_all
    Artist.delete_all
    Library.where.not(id: @fixture_library_ids).delete_all
  end

  def create_user
    User.create!(email: "resume-smoke-#{SecureRandom.uuid}@example.com", password: "foobar123")
  end

  # A valid Radio_Station in the given Station_State: it needs criteria that
  # select at least one authorized Song to save, so a dedicated owned library +
  # Artist/Album/Song triad is created and selected by artist.
  def build_station(state:, created_at: @now)
    owner = create_user
    library = Library.create!(name: "Resume-Lib-#{next_seq}", kind: "local", media_path: MEDIA_PATH, owner: owner)
    n = next_seq
    artist = Artist.create!(name: "Artist-#{n}", library: library)
    album = Album.create!(name: "Album-#{n}", artist: artist, library: library, genre: "rock")
    Song.create!(
      name: "Song-#{n}",
      file_path: "/tmp/resume-song-#{n}.mp3",
      file_path_hash: "fph-#{n}",
      md5_hash: "md5-#{n}",
      library: library,
      album: album,
      artist: artist
    )

    station = RadioStation.new(user: owner, name: "Station-#{next_seq}", state: state, created_at: created_at)
    station.station_source_criteria.build(criterion_type: "artist", artist_id: artist.id)
    station.save!
    station
  end

  # A Co_Listen_Session in the given Session_State. A `perpetual` session never
  # expires; a bounded (`hours`/`days`) session with a `created_at` older than
  # its duration is already expired.
  def build_session(state:, kind: "perpetual", value: nil, created_at: @now)
    CoListenSession.create!(
      user: create_user,
      state: state,
      session_duration_kind: kind,
      session_duration_value: kind == "perpetual" ? nil : value,
      created_at: created_at
    )
  end
end
