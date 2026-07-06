# frozen_string_literal: true

require "test_helper"

# Property-based test for the concurrency-cap seam of the radio-party-colisten
# feature (design Property 25).
#
# The Admin-configurable `max_concurrent_streams` setting caps the number of
# *live broadcasts* — every `started` Radio_Station plus every `active`
# Co_Listen_Session (Req 10.5). StationLifecycleService#start and
# SessionLifecycleService#activate enforce this cap against the current live
# count (via BroadcastLifecycle#capacity_available?): a transition succeeds iff
# the live count is below the cap, and exceeding it is rejected with an
# `:at_capacity` error that leaves the subject's state unchanged (Req 10.6,
# 10.7).
#
# Each iteration builds an isolated dataset — a generated number of pre-existing
# live broadcasts (a mix of started stations and active co-listen sessions) plus
# one stopped station or one ended session to act on — and drives the real
# lifecycle service with a generated cap. Because the cap and the live-broadcast
# count are read from the database, this exercise touches the DB, so the feature
# data is reset per iteration exactly as radio_station_property_test does.
class ConcurrencyCapPropertyTest < ActiveSupport::TestCase
  # A readable directory so freshly created local libraries pass media-path
  # validation; the fixtures directory always exists.
  MEDIA_PATH = Rails.root.join("test", "fixtures", "files").to_s

  setup do
    @seq = 0
    @fixture_library_ids = [ libraries(:default_library).id, libraries(:secondary_library).id ]
  end

  # Feature: radio-party-colisten, Property 25: Concurrency cap on start/activate
  test "starting a station or activating a co-listen session succeeds iff the live-broadcast count is below the Admin cap, and exceeding it is rejected with a capacity error that leaves state unchanged" do
    check_property(iterations: 100) do
      # The concurrency cap: either unbounded (nil) or a small non-negative
      # integer so the below/at/above-capacity cases are all exercised.
      bounded = choose(true, false)
      cap = bounded ? range(0, 5) : nil
      # The pre-existing live broadcasts, split across the two kinds so a mixed
      # count is exercised.
      pre_started_stations = range(0, 4)
      pre_active_sessions = range(0, 4)
      # Which kind of broadcast we attempt to bring live this iteration.
      subject_kind = choose(:station, :session)

      [ cap, pre_started_stations, pre_active_sessions, subject_kind ]
    end.check do |(cap, pre_started_stations, pre_active_sessions, subject_kind)|
      reset_dataset!
      Setting.update(max_concurrent_streams: cap)

      # Seed the pre-existing live-broadcast count.
      pre_started_stations.times { build_station(state: :started) }
      pre_active_sessions.times { build_session(state: :active) }
      live_count = pre_started_stations + pre_active_sessions

      # A cap of nil is unbounded; otherwise capacity remains iff the live count
      # is strictly below the cap.
      expected_success = cap.nil? || live_count < cap

      # Task 9.3 wires start/activate to the Broadcaster; inject an available
      # fake so this property isolates the concurrency-cap decision (a real
      # Broadcaster would otherwise be an unrelated dependency here).
      broadcaster = FakeBroadcaster.new

      if subject_kind == :station
        subject = build_station(state: :stopped)
        result = StationLifecycleService.new(subject, broadcaster: broadcaster).start(actor: subject.user)
        live_state = :started
        idle_state = :stopped
      else
        subject = build_session(state: :ended)
        result = SessionLifecycleService.new(subject, broadcaster: broadcaster).activate(actor: subject.user)
        live_state = :active
        idle_state = :ended
      end

      assert_equal expected_success, result.ok?,
        "#{subject_kind} should go live iff live count (#{live_count}) is below the cap (#{cap.inspect})"

      subject.reload
      if expected_success
        assert_nil result.error, "a successful transition carries no error"
        assert_equal live_state.to_s, subject.state,
          "a successful transition leaves the #{subject_kind} live (#{live_state})"
      else
        assert_equal BroadcastLifecycle::ERROR_AT_CAPACITY, result.error,
          "exceeding the cap is rejected with a capacity error"
        assert_equal idle_state.to_s, subject.state,
          "a rejected transition leaves the #{subject_kind} in its prior state (#{idle_state})"
      end
    end
  end

  private

  def next_seq
    @seq += 1
  end

  # Wipe all feature records and every non-fixture library/content row so each
  # iteration observes only the live broadcasts it seeds.
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
    User.create!(email: "cap-prop-#{SecureRandom.uuid}@example.com", password: "foobar123")
  end

  # Build a persisted Radio_Station in the given Station_State. A station needs
  # criteria that select at least one authorized Song to save, so a dedicated
  # owned library + Artist/Album/Song triad is created and selected by artist.
  def build_station(state:)
    owner = create_user
    library = Library.create!(name: "Cap-Lib-#{next_seq}", kind: "local", media_path: MEDIA_PATH, owner: owner)
    n = next_seq
    artist = Artist.create!(name: "Artist-#{n}", library: library)
    album = Album.create!(name: "Album-#{n}", artist: artist, library: library, genre: "rock")
    Song.create!(
      name: "Song-#{n}",
      file_path: "/tmp/cap-song-#{n}.mp3",
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

  # Build a persisted Co_Listen_Session in the given Session_State. An empty
  # shared-library set is a valid subset of any host's authorization.
  def build_session(state:)
    CoListenSession.create!(user: create_user, state: state)
  end
end
