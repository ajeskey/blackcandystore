# frozen_string_literal: true

require "test_helper"

# Property-based test for Property 15 of the remote-library-mirror-sync feature.
#
# Design property (remote-library-mirror-sync, Property 15):
#   For any nudge token presented at the Nudge_Endpoint against any set of held
#   Library_Connections in arbitrary states, the Redeeming_Server SHALL schedule
#   an immediate Incremental_Sync if and only if the token maps to a
#   Library_Connection it holds that is active; a nudge whose token maps to no
#   held connection (unknown token) or to a non-active connection SHALL be
#   ignored; and in every case the endpoint SHALL return 204 without disclosing
#   whether a connection exists (Req 6.2, 6.5). Independently of any nudge, the
#   mirror still converges through the next scheduled Incremental_Sync, so a
#   nudge is only an optimization and never required for correctness (Req 6.4).
#
# This is an integration-style property test that drives the real HTTP path:
# `POST /nudges { nudge_token }`, exactly as a Hosting_Server would call it.
# `NudgesController#create` looks up the LibraryConnection by `nudge_token` and
# enqueues an incremental `CatalogSyncJob` only when the connection is found and
# active, always returning 204.
#
# `nudge_token` carries a unique index, so a token resolves to at most one
# connection; "maps to a held connection" is therefore structurally a single
# match or none. Job scheduling is observed through the ActiveJob :test adapter
# (`enqueued_jobs` / `assert_enqueued_with`); the endpoint's 204 is asserted in
# every branch so unknown and inactive tokens are ignored without disclosure.
class NudgeConnectionMappingPropertyTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  BASE_URL = "https://remote.example.com"

  setup do
    @seq = 0
    @user = users(:admin)

    # Snapshot any pre-existing connection ids so each iteration can delete only
    # the connections it built and reason about just its own dataset.
    @fixture_connection_ids = LibraryConnection.ids
  end

  # Feature: remote-library-mirror-sync, Property 15: A catalog nudge schedules a sync exactly when it maps to a held connection
  test "a nudge schedules an immediate incremental sync iff its token maps to a held, active connection, always returns 204, and the mirror still converges via the scheduler regardless" do
    check_property(iterations: 120) do
      # A set of held connections in arbitrary lifecycle states.
      conn_states = Array.new(range(1, 4)) { choose(:active, :revoked, :unavailable) }

      # Which token to present at the endpoint:
      #   :held    -> the nudge_token of one held connection (index below),
      #   :unknown -> a token matching no held connection,
      #   :blank   -> an empty token (also matches nothing).
      token_kind = choose(:held, :unknown, :blank)
      held_index = range(0, conn_states.size - 1)

      [ conn_states, token_kind, held_index ]
    end.check do |(conn_states, token_kind, held_index)|
      reset_state
      clear_enqueued_jobs

      # Materialize the held connections, each with a distinct nudge_token
      # (globally unique via the token's unique index) and a distinct
      # remote_library_id (the connection uniqueness index).
      connections = conn_states.map.with_index do |status, i|
        create_connection(status: status, nudge_token: "nudge-#{next_seq}", remote_library_id: 1000 + i)
      end

      presented_token =
        case token_kind
        when :held then connections[held_index].nudge_token
        when :blank then ""
        else "unknown-#{next_seq}" # matches no held connection
        end

      # Independently compute the expected outcome: a token resolves to at most
      # one held connection (unique index), and a sync is scheduled iff that
      # connection exists and is active.
      matched = presented_token.blank? ? nil : connections.find { |c| c.nudge_token == presented_token }
      should_enqueue = !matched.nil? && matched.active?

      post "/nudges", params: { nudge_token: presented_token }, as: :json

      # The endpoint always answers 204, disclosing nothing about whether a
      # connection exists for the token (Req 6.5).
      assert_response :no_content
      assert_empty @response.body.to_s, "expected the nudge endpoint to return no body"

      # Only CatalogSyncJobs scheduled for the connections this iteration built
      # are relevant to the mapping assertion.
      built_ids = connections.map(&:id)
      sync_jobs = enqueued_jobs.select do |job|
        job[:job] == CatalogSyncJob && built_ids.include?(job[:args].first)
      end

      if should_enqueue
        assert_equal 1, sync_jobs.size,
          "expected exactly one incremental sync scheduled for the matched active connection"
        assert_enqueued_with(job: CatalogSyncJob, args: [ matched.id, { mode: :incremental } ])
      else
        assert_empty sync_jobs,
          "expected no sync scheduled for an unknown token or a non-active connection"
      end

      # Req 6.4: convergence never depends on the nudge. Whether or not a nudge
      # was received (and whether or not it scheduled a sync), every active held
      # connection remains covered by the recurring Sync_Scheduler, which drives
      # `LibraryConnection.active`. So the next scheduled Incremental_Sync would
      # still reconcile each active connection's mirror.
      expected_active_ids = connections.select(&:active?).map(&:id).sort
      scheduler_covered_ids = LibraryConnection.active.where(id: built_ids).ids.sort
      assert_equal expected_active_ids, scheduler_covered_ids,
        "expected every active connection to remain schedulable regardless of nudge delivery"
    end
  end

  private

  def next_seq
    @seq += 1
  end

  # Remove only the connections this test built so each iteration observes just
  # its own dataset. destroy_all triggers the dependent teardown, though these
  # connections carry no mirror Library.
  def reset_state
    LibraryConnection.where.not(id: @fixture_connection_ids).destroy_all
  end

  def create_connection(status:, nudge_token:, remote_library_id:)
    LibraryConnection.create!(
      user: @user,
      server_base_url: BASE_URL,
      remote_library_id: remote_library_id,
      grant_token: "grant-#{next_seq}",
      status: status,
      nudge_token: nudge_token
    )
  end
end
