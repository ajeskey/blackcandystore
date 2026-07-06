# frozen_string_literal: true

require "test_helper"
require "puma/plugin/resume_streams"

# End-to-end BOOT-WIRING smoke test for the server-restart resume path of the
# radio-party-colisten feature (task 15.3).
#
# ResumeStreamsJobSmokeTest (task 9.5) exhaustively covers the job's
# re-establishment behavior across kinds, ordering, the concurrency cap, and an
# unavailable Broadcaster. This test covers the complementary BOOT WIRING: that
# the pieces the server actually relies on at startup fit together end to end —
#
#   1. the boot resume path (ResumeStreamsJob#perform) re-establishes BOTH a
#      started Radio_Station AND an active, non-expired Co_Listen_Session
#      together, in a single run, through the injected fake Broadcaster
#      (Req 10.4 + Req 10.10 exercised jointly); and
#   2. the Puma boot plugin (lib/puma/plugin/resume_streams.rb) is what enqueues
#      ResumeStreamsJob on boot — and only outside the test environment.
#
# The Broadcaster is the injected in-memory FakeBroadcaster (test/support), so
# no out-of-process service is required.
#
# _Requirements: 10.4, 10.10 (boot resume re-establishment wiring)_
class ResumeStreamsBootWiringTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  # A readable directory so freshly created local libraries pass media-path
  # validation; the fixtures directory always exists.
  MEDIA_PATH = Rails.root.join("test", "fixtures", "files").to_s

  # Reuses the real (pure) id/kind derivation but returns a fixed continuity
  # directive for `next_source`, keeping the smoke test hermetic (no
  # path/token/filesystem resolution) while still handing the resume job the
  # real Broadcaster-facing broadcast ids.
  class StubSource < BroadcastSource
    def next_source(_subject, history: [])
      { type: BroadcastSource::SOURCE_CONTINUITY }
    end
  end

  # Minimal stand-ins for Puma's launcher/events so the plugin's boot hook can be
  # driven without booting a real web server. `on_booted` captures the block the
  # plugin registers so the test can fire it deliberately.
  class FakeEvents
    attr_reader :booted_block

    def on_booted(&block)
      @booted_block = block
    end
  end

  class FakeLauncher
    def events
      @events ||= FakeEvents.new
    end
  end

  setup do
    @seq = 0
    @fixture_library_ids = [ libraries(:default_library).id, libraries(:secondary_library).id ]
    @now = Time.current
    @source = BroadcastSource.new
  end

  test "boot resume re-establishes a started station and an active co-listen session together in one run" do
    reset_dataset!
    Setting.update(max_concurrent_streams: nil)

    station = build_station(state: :started, created_at: @now - 2.minutes)
    session = build_session(state: :active, created_at: @now - 1.minute)

    broadcaster = FakeBroadcaster.new
    ResumeStreamsJob.new.perform(now: @now, broadcaster: broadcaster, source: StubSource.new)

    started = broadcaster.started
    started_ids = started.map { |call| call[:broadcast_id] }

    # Both broadcasts, and only those two, are re-established in a single boot
    # run — oldest first (the station precedes the session).
    assert_equal(
      [ @source.identifier(station), @source.identifier(session) ],
      started_ids,
      "boot resume must re-establish exactly the started station then the active session"
    )

    # Each broadcast is re-established under its own kind, proving the station
    # and session paths are wired together rather than one masking the other.
    kinds = started.map { |call| [ call[:broadcast_id], call[:kind] ] }.to_h
    assert_equal BroadcastSource::KIND_RADIO, kinds[@source.identifier(station)]
    assert_equal BroadcastSource::KIND_CO_LISTEN, kinds[@source.identifier(session)]
  end

  test "the Puma boot plugin enqueues ResumeStreamsJob when the server boots outside test" do
    launcher = FakeLauncher.new

    plugin = Puma::Plugins.find("resume_streams").new
    plugin.start(launcher)

    booted = launcher.events.booted_block
    assert_not_nil booted, "the plugin must register an on_booted hook"

    # Outside the test environment the boot hook enqueues the resume job.
    Rails.stub(:env, ActiveSupport::StringInquirer.new("production")) do
      assert_enqueued_with(job: ResumeStreamsJob) do
        booted.call
      end
    end
  end

  test "the Puma boot plugin does not enqueue ResumeStreamsJob during the test suite" do
    launcher = FakeLauncher.new

    plugin = Puma::Plugins.find("resume_streams").new
    plugin.start(launcher)

    # The guard keeps resume from firing during the test suite / rake tasks.
    assert Rails.env.test?, "sanity: this assertion documents the guarded environment"
    assert_no_enqueued_jobs do
      launcher.events.booted_block.call
    end
  end

  private

  def next_seq
    @seq += 1
  end

  # Wipe all feature records and every non-fixture library/content row so the
  # boot run observes only the single station and single session built here.
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
    User.create!(email: "resume-boot-#{SecureRandom.uuid}@example.com", password: "foobar123")
  end

  # A valid started/stopped Radio_Station: it needs criteria selecting at least
  # one authorized Song to save, so a dedicated owned library + Artist/Album/Song
  # triad is created and selected by artist.
  def build_station(state:, created_at: @now)
    owner = create_user
    library = Library.create!(name: "Resume-Lib-#{next_seq}", kind: "local", media_path: MEDIA_PATH, owner: owner)
    n = next_seq
    artist = Artist.create!(name: "Artist-#{n}", library: library)
    album = Album.create!(name: "Album-#{n}", artist: artist, library: library, genre: "rock")
    Song.create!(
      name: "Song-#{n}",
      file_path: "/tmp/resume-boot-song-#{n}.mp3",
      file_path_hash: "fph-boot-#{n}",
      md5_hash: "md5-boot-#{n}",
      library: library,
      album: album,
      artist: artist
    )

    station = RadioStation.new(user: owner, name: "Station-#{next_seq}", state: state, created_at: created_at)
    station.station_source_criteria.build(criterion_type: "artist", artist_id: artist.id)
    station.save!
    station
  end

  # An `active`, perpetual (never-expiring) Co_Listen_Session.
  def build_session(state:, created_at: @now)
    CoListenSession.create!(
      user: create_user,
      state: state,
      session_duration_kind: "perpetual",
      session_duration_value: nil,
      created_at: created_at
    )
  end
end
