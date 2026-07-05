# frozen_string_literal: true

require "test_helper"

# Integration / smoke tests for the Sync_Scheduler timing and the sync job
# wiring (remote-library-mirror-sync, task 10.3).
#
# These are NOT property-based tests. They exercise the plumbing that connects
# the schedule, the redemption path, and the incremental/full sync drivers to
# the queue and the Changes_Since_API — the pieces the design marks as
# integration/smoke tested rather than property tested (scheduler timing and
# job wiring):
#
#   * the recurring Sync_Scheduler (`CatalogSyncJob.enqueue_all_active`) enqueues
#     exactly one incremental CatalogSyncJob per ACTIVE Library_Connection and
#     none for a revoked/unavailable connection                        (Req 4.1)
#   * the recurring task in config/recurring.yml maps to that entry point and
#     its interval reflects BlackCandy.config.catalog_sync_poll_interval, with
#     the 15-minute default applied when unset                         (Req 4.5)
#   * an Incremental_Sync issues changes_since with the connection's recorded
#     Sync_Cursor                                                      (Req 4.2)
#   * when the host answers `full_sync_required: true`, the Full_Sync branch is
#     taken (the browse endpoints are called and the mirror is rebuilt) (Req 4.4)
#   * a NEW-connection redemption enqueues exactly one full-mode CatalogSyncJob,
#     while a re-redemption reusing an existing connection enqueues none (Req 1.1)
#
# The queue is the ActiveJob :test adapter; the hosting Server is stubbed with
# WebMock (the suite disallows real net connections).
class SchedulerSyncWiringTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  BASE_URL = "https://remote.example.com"
  GRANT_TOKEN = "remote-bearer-token"

  setup do
    @user = users(:admin)
  end

  # --- 1. Scheduler enqueues one incremental job per active connection -------

  # Req 4.1: while a Library_Connection is active, the Sync_Scheduler triggers
  # an Incremental_Sync for it on the schedule. enqueue_all_active is that
  # trigger; it must enqueue exactly one incremental CatalogSyncJob per active
  # connection and none for a non-active (revoked/unavailable) one.
  test "enqueue_all_active enqueues exactly one incremental job per active connection and none for inactive" do
    active_a = create_connection(remote_library_id: 1, status: :active)
    active_b = create_connection(remote_library_id: 2, status: :active)
    create_connection(remote_library_id: 3, status: :revoked)
    create_connection(remote_library_id: 4, status: :unavailable)

    assert_enqueued_jobs 2, only: CatalogSyncJob do
      CatalogSyncJob.enqueue_all_active
    end

    # Each active connection gets exactly one job, and it is the incremental mode.
    assert_enqueued_with(job: CatalogSyncJob, args: [ active_a.id, { mode: :incremental } ])
    assert_enqueued_with(job: CatalogSyncJob, args: [ active_b.id, { mode: :incremental } ])

    # No job is enqueued for the revoked/unavailable connections.
    enqueued_ids = enqueued_jobs.select { |job| job[:job] == CatalogSyncJob }.map { |job| job[:args].first }
    assert_equal [ active_a.id, active_b.id ].sort, enqueued_ids.sort
  end

  test "enqueue_all_active enqueues nothing when there are no active connections" do
    create_connection(remote_library_id: 5, status: :revoked)

    assert_no_enqueued_jobs only: CatalogSyncJob do
      CatalogSyncJob.enqueue_all_active
    end
  end

  # --- 2. The recurring task maps to the scheduler at the configured interval -

  # Req 4.1, 4.5: the recurring task drives enqueue_all_active every
  # Poll_Interval, and the interval is BlackCandy.config.catalog_sync_poll_interval
  # (minutes) with a 15-minute default when unset.
  test "the recurring task runs enqueue_all_active on the configured poll interval with the default applied" do
    config = load_recurring_config

    scheduler = config.fetch("catalog_sync_scheduler")
    assert_equal "CatalogSyncJob.enqueue_all_active", scheduler.fetch("command")

    # The default Poll_Interval is 15 minutes when CATALOG_SYNC_POLL_INTERVAL is
    # unset (Req 4.5); the rendered schedule reflects that config value.
    assert_equal 15, BlackCandy.config.catalog_sync_poll_interval
    assert_equal "every #{BlackCandy.config.catalog_sync_poll_interval} minutes", scheduler.fetch("schedule")
  end

  test "the poll interval is configurable via the environment and the schedule reflects it" do
    with_env("CATALOG_SYNC_POLL_INTERVAL" => "30") do
      assert_equal 30, BlackCandy.config.catalog_sync_poll_interval

      scheduler = load_recurring_config.fetch("catalog_sync_scheduler")
      assert_equal "every 30 minutes", scheduler.fetch("schedule")
    end
  ensure
    # The config memoizes nothing (it re-reads ENV each call), so leaving the
    # block restores the default automatically.
    assert_equal 15, BlackCandy.config.catalog_sync_poll_interval
  end

  # --- 3. Incremental_Sync passes the recorded Sync_Cursor (Req 4.2) ---------

  # Req 4.2: when an Incremental_Sync runs, the redeemer requests Catalog_Changes
  # using the Library_Connection's recorded Sync_Cursor. Running the job for an
  # incremental sync must issue changes_since with cursor=<recorded>.
  test "an incremental sync requests changes using the connection's recorded sync_cursor" do
    connection = create_connection(remote_library_id: 100, status: :active)
    build_mirror(connection)
    connection.update!(sync_cursor: 7)

    stub = stub_request(:get, changes_url(100))
      .with(query: { cursor: 7, page: 1 })
      .to_return(status: 200, body: { catalog_version: 7, full_sync_required: false, changes: [] }.to_json)
    # The pager confirms it has read the whole delta by fetching until a page
    # comes back empty; page 2 (still keyed on the recorded cursor) closes it.
    stub_request(:get, changes_url(100))
      .with(query: { cursor: 7, page: 2 })
      .to_return(status: 200, body: { catalog_version: 7, full_sync_required: false, changes: [] }.to_json)

    # Drive it through the queued entry point in the default (incremental) mode
    # so the whole job -> engine -> client wiring runs.
    CatalogSyncJob.perform_now(connection.id)

    assert_requested(stub)
    assert_equal 7, connection.reload.sync_cursor
    assert_equal "fresh", connection.sync_state
  end

  # --- 4. full_sync_required takes the Full_Sync branch (Req 4.4) ------------

  # Req 4.4: when the Changes_Since_API indicates a Full_Sync is required, the
  # redeemer performs a Full_Sync instead of applying an incremental change set.
  # Reaching the browse endpoints (which only the Full_Sync path calls) and
  # rebuilding the mirror from them proves the branch was taken.
  test "an incremental sync takes the full-sync branch when the host signals full_sync_required" do
    connection = create_connection(remote_library_id: 200, status: :active)
    build_mirror(connection)
    connection.update!(sync_cursor: 3)

    # The host can no longer serve the recorded cursor incrementally.
    stub_request(:get, changes_url(200))
      .with(query: { cursor: 3, page: 1 })
      .to_return(status: 200, body: { catalog_version: 20, full_sync_required: true, changes: [] }.to_json)

    # The Full_Sync branch browses the host catalog (artists, then albums, then
    # songs), paging until a page comes back empty.
    artists_stub = stub_browse(200, "artists", 1, [ host_artist(1, "artist-1") ])
    stub_browse(200, "artists", 2, [])
    albums_stub = stub_browse(200, "albums", 1, [ host_album(1, "album-1", artist_id: 1) ])
    stub_browse(200, "albums", 2, [])
    songs_stub = stub_browse(200, "songs", 1, [ host_song(1, "song-1", album_id: 1, artist_id: 1) ])
    stub_browse(200, "songs", 2, [])

    CatalogSyncJob.perform_now(connection.id)

    # The browse endpoints only the Full_Sync path calls were hit.
    assert_requested(artists_stub)
    assert_requested(albums_stub)
    assert_requested(songs_stub)

    connection.reload
    # The mirror was rebuilt to exactly the host's current catalog, and the
    # cursor adopted the version the host reported alongside full_sync_required.
    assert_equal 20, connection.sync_cursor
    assert_equal "fresh", connection.sync_state
    assert_equal [ 1 ], Song.in_library(connection.library).pluck(:remote_song_id)
    assert_equal [ 1 ], Album.in_library(connection.library).pluck(:remote_album_id)
    assert_equal [ 1 ], Artist.in_library(connection.library).pluck(:remote_artist_id)
  end

  # --- 5. Redemption enqueues a Full_Sync only on new-connection creation ----

  REMOTE_CONFIRM_URL = "#{BASE_URL}/federation/grants/confirm"

  # Req 1.1: a first-established Library_Connection triggers a Full_Sync that
  # materializes the mirror. The redemption path must enqueue exactly one
  # full-mode CatalogSyncJob when it creates a NEW connection.
  test "a new-connection redemption enqueues exactly one full-mode CatalogSyncJob" do
    token = "redeem-new-secret"
    stub_confirm_success(library_id: 501)

    connection = nil
    assert_enqueued_jobs 1, only: CatalogSyncJob do
      result = InviteManager.redeem(invite_code: remote_code(token), user: @user)
      connection = result.connection
    end

    assert_not_nil connection
    assert_enqueued_with(job: CatalogSyncJob, args: [ connection.id, { mode: :full } ])
  end

  # Req 1.1: re-redemption that reuses an existing connection must NOT re-trigger
  # a Full_Sync, so no CatalogSyncJob is enqueued the second time.
  test "a re-redemption reusing an existing connection enqueues no CatalogSyncJob" do
    token = "redeem-reuse-secret"
    stub_confirm_success(library_id: 502)

    # First redemption creates the connection (and enqueues the full sync).
    first = InviteManager.redeem(invite_code: remote_code(token), user: @user)

    # Second redemption reuses the same connection and must enqueue nothing.
    assert_no_enqueued_jobs only: CatalogSyncJob do
      second = InviteManager.redeem(invite_code: remote_code(token), user: @user)
      assert_equal first.connection.id, second.connection.id
    end
  end

  private

  def create_connection(remote_library_id:, status:)
    LibraryConnection.create!(
      user: @user,
      server_base_url: BASE_URL,
      remote_library_id: remote_library_id,
      grant_token: GRANT_TOKEN,
      status: status
    )
  end

  # Attach a browsable remote Library (the Catalog_Mirror) to a connection so
  # the sync engine has a mirror to reconcile.
  def build_mirror(connection)
    Library.create!(
      name: "Mirror-#{SecureRandom.hex(4)}",
      kind: :remote,
      owner: @user,
      library_connection: connection
    )
  end

  def changes_url(remote_library_id)
    "#{BASE_URL}/federation/libraries/#{remote_library_id}/changes"
  end

  def stub_browse(remote_library_id, type, page, rows)
    stub_request(:get, "#{BASE_URL}/federation/libraries/#{remote_library_id}/#{type}")
      .with(query: { page: page })
      .to_return(status: 200, body: rows.to_json, headers: { "Content-Type" => "application/json" })
  end

  def host_artist(id, name, is_various: false)
    { id: id, name: name, is_various: is_various }
  end

  def host_album(id, name, artist_id:)
    { id: id, name: name, year: 2020, genre: "genre-1", artist_id: artist_id, artist_name: "artist-#{artist_id}" }
  end

  def host_song(id, name, album_id:, artist_id:)
    {
      id: id, name: name, duration: 200, tracknum: 1, discnum: 1,
      album_id: album_id, album_name: "album-#{album_id}",
      artist_id: artist_id, artist_name: "artist-#{artist_id}"
    }
  end

  def load_recurring_config
    raw = File.read(Rails.root.join("config", "recurring.yml"))
    rendered = ERB.new(raw).result
    parsed = YAML.load(rendered, aliases: true)
    parsed[Rails.env.to_s] || parsed["default"]
  end

  def remote_code(token)
    InviteManager.encode(server_base_url: BASE_URL, secret_token: token)
  end

  def stub_confirm_success(library_id:)
    stub_request(:post, REMOTE_CONFIRM_URL).to_return(
      status: 200,
      body: { library: { id: library_id, name: "Shared Library" }, valid: true }.to_json,
      headers: { "Content-Type" => "application/json" }
    )
  end
end
