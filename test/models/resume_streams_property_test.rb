# frozen_string_literal: true

require "test_helper"

# Property-based test for Property 26 of the radio-party-colisten feature.
#
# Design property (radio-party-colisten, Property 26):
#   For any set of persisted Radio_Stations and Co_Listen_Sessions in arbitrary
#   states and any concurrency cap, a server restart resumes exactly the
#   Radio_Stations that were `started` and the Co_Listen_Sessions that were
#   `active` and not expired, up to the concurrency cap; any session whose
#   Session_Duration has expired is treated as ended and is never resumed.
#
#   Validates: Requirements 10.4, 10.10, 12.4
#
# This exercises the pure resume decision — ResumeStreamsJob#resumable_broadcasts
# — directly, without the Broadcaster. Each iteration builds an isolated mix of
# Radio_Stations (`started`/`stopped`) and Co_Listen_Sessions (`active`/`ended`,
# with `perpetual`/`hours`/`days` durations that are either already expired or
# still live as of a fixed reference time) plus an arbitrary concurrency cap
# (including an unbounded nil cap).
#
# The expected eligible set is derived independently from the generated spec:
#   * a station is eligible iff it is `started`;
#   * a session is eligible iff it is `active` AND its Session_Duration has not
#     elapsed by `now` (perpetual never elapses; a bounded duration elapses when
#     `created_at + duration <= now`).
# The eligible broadcasts are then ordered oldest-first (the job's documented
# deterministic order: `[created_at, class.name, id]`) and truncated to the cap,
# so the assertion validates selection, expiration handling, and the cap's
# "oldest win the available capacity" rule together.
class ResumeStreamsPropertyTest < ActiveSupport::TestCase
  # A readable directory so freshly created local libraries pass media-path
  # validation; the fixtures directory always exists.
  MEDIA_PATH = Rails.root.join("test", "fixtures", "files").to_s

  setup do
    @seq = 0
    @fixture_library_ids = [ libraries(:default_library).id, libraries(:secondary_library).id ]
    @now = Time.current
    @job = ResumeStreamsJob.new
  end

  # Feature: radio-party-colisten, Property 26: Restart resume re-establishes exactly the eligible broadcasts
  test "resume re-establishes exactly the started stations and active non-expired sessions, up to the concurrency cap" do
    check_property(iterations: 100) do
      # A mix of stations (each started or not) and sessions (each with a state,
      # duration kind/value, and whether it should already be expired), plus a
      # concurrency cap that is either unbounded (nil) or a small integer that
      # may or may not bind.
      station_started = Array.new(range(0, 5)) { choose(true, false) }
      sessions = Array.new(range(0, 5)) do
        [ choose(true, false), choose("perpetual", "hours", "days"), range(1, 72), choose(true, false) ]
      end
      cap = choose(nil, 0, 1, 2, 3, 10)

      [ station_started, sessions, cap ]
    end.check do |(station_started, session_specs, cap)|
      reset_dataset!
      owner, artist = build_owner_and_criterion_target

      Setting.update(max_concurrent_streams: cap)

      stations = build_stations(owner, artist, station_started)
      sessions = build_sessions(owner, session_specs)

      # Independent oracle: which built records are eligible to resume.
      eligible = []
      stations.each { |s| eligible << s.record if s.started }
      sessions.each { |s| eligible << s.record if s.active && !s.expired }

      # The job's documented deterministic order, then the cap truncation.
      ordered = eligible.sort_by { |b| [ b.created_at, b.class.name, b.id ] }
      expected = cap.nil? ? ordered : ordered.first([ cap.to_i, 0 ].max)

      actual = @job.resumable_broadcasts(now: @now)

      assert_equal expected, actual,
        "resume must re-establish exactly the eligible broadcasts (cap=#{cap.inspect})"

      # Nothing ineligible may ever be resumed, regardless of the cap.
      excluded_stations = stations.reject(&:started).map(&:record)
      ended_sessions = sessions.reject(&:active).map(&:record)
      expired_sessions = sessions.select(&:expired).map(&:record)
      (excluded_stations + ended_sessions + expired_sessions).each do |record|
        assert_not_includes actual, record,
          "a #{record.class.name} that is stopped/ended/expired must never be resumed"
      end

      # The cap is honored: never more than the cap, and never more than exist.
      max_allowed = cap.nil? ? eligible.size : [ [ cap.to_i, 0 ].max, eligible.size ].min
      assert_equal max_allowed, actual.size,
        "resume must honor the concurrency cap (cap=#{cap.inspect})"
    end
  end

  private

  # Wipe all station/session/content and every non-fixture library so each
  # iteration observes only the dataset it builds.
  def reset_dataset!
    CoListenSession.delete_all
    StationSourceCriterion.delete_all
    RadioStation.delete_all
    Song.delete_all
    Album.delete_all
    Artist.delete_all
    Library.where.not(id: @fixture_library_ids).delete_all
  end

  # A fresh owning User with one owned local library holding a single Song, and
  # the Artist that a station's criterion can select so the station is valid
  # (its criteria must select at least one authorized song).
  def build_owner_and_criterion_target
    owner = User.create!(email: "prop26-owner-#{SecureRandom.uuid}@example.com", password: "foobar123")
    library = Library.create!(name: "Prop26-#{next_seq}", kind: "local", media_path: MEDIA_PATH, owner: owner)
    n = next_seq
    artist = Artist.create!(name: "Artist-#{n}", library: library)
    album = Album.create!(name: "Album-#{n}", artist: artist, library: library)
    Song.create!(
      name: "Song-#{n}",
      file_path: "/tmp/prop26-song-#{n}.mp3",
      file_path_hash: "fph-#{n}",
      md5_hash: "md5-#{n}",
      library: library,
      album: album,
      artist: artist
    )

    [ owner, artist ]
  end

  StationSpec = Struct.new(:record, :started)
  SessionSpec = Struct.new(:record, :active, :expired)

  # Create the stations described by the started-mask. Each is a valid station
  # (an artist criterion selecting the owner's one authorized song); its
  # Station_State is `started` or `stopped` per the mask. created_at is spread
  # into the past so the resume order is deterministic.
  def build_stations(owner, artist, station_started)
    station_started.each_with_index.map do |started, i|
      station = RadioStation.new(
        user: owner,
        name: "Station-#{next_seq}",
        state: started ? "started" : "stopped",
        created_at: @now - (i + 1).minutes
      )
      station.station_source_criteria.build(criterion_type: "artist", artist: artist)
      station.save!
      StationSpec.new(station, started)
    end
  end

  # Create the sessions described by the specs. A `perpetual` session never
  # expires; a bounded (`hours`/`days`) session is aged so that it is already
  # expired (created_at + duration <= now) or still live per its `want_expired`
  # flag. created_at is otherwise spread into the past for a deterministic order.
  def build_sessions(owner, session_specs)
    session_specs.each_with_index.map do |(active, kind, value, want_expired), j|
      duration = kind == "hours" ? value.hours : value.days
      created_at =
        if kind == "perpetual"
          @now - (j + 1).minutes
        elsif want_expired
          @now - duration - (j + 1).minutes
        else
          @now - (j + 1).minutes
        end

      session = CoListenSession.create!(
        user: owner,
        state: active ? "active" : "ended",
        session_duration_kind: kind,
        session_duration_value: kind == "perpetual" ? nil : value,
        created_at: created_at
      )

      expired = kind != "perpetual" && (created_at + duration) <= @now
      SessionSpec.new(session, active, expired)
    end
  end

  def next_seq
    @seq += 1
  end
end
