# frozen_string_literal: true

require "test_helper"

# Integration / smoke test for the best-effort Catalog_Nudge network path
# (remote-library-mirror-sync, task 12.3).
#
# This is NOT a property test. It exercises the fire-and-forget push nudge the
# Hosting_Server sends when a Local_Library's catalog changes:
#
#   catalog change --CatalogVersioning--> enqueue CatalogNudgeJob(library_id)
#     CatalogNudgeJob --POST { nudge_token }--> each active grant's callback URL
#
# Every redeemer callback is stubbed with WebMock (the suite disallows real net
# connections), so we assert the sender's behavior against the Cross-Server HTTP
# API Contract and the best-effort guarantees without a live peer:
#
#   * a catalog change enqueues one CatalogNudgeJob for the changed library
#     and performing it POSTs { nudge_token } to each ACTIVE grant that
#     registered a nudge_callback_url; grants without a callback and revoked
#     grants receive nothing                                        (Req 6.1)
#   * an unreachable redeemer (timeout / connection refused) is a non-fatal
#     miss: the job completes without raising, issues no retry storm (exactly
#     one attempt per grant), and leaves both the Catalog (catalog_version and
#     the CatalogChange log) and the Access_Grant unchanged          (Req 6.3)
class CatalogNudgeJobTest < ActiveJob::TestCase
  CALLBACK_A = "https://redeemer-a.example.com/nudges"
  CALLBACK_B = "https://redeemer-b.example.com/nudges"
  REVOKED_CALLBACK = "https://redeemer-revoked.example.com/nudges"

  setup do
    @library = libraries(:default_library)

    # Two redeemers with active grants that registered a callback + token.
    @grant_a = AccessGrant.create!(
      library: @library,
      token: "grant-token-a-#{SecureRandom.hex(4)}",
      nudge_callback_url: CALLBACK_A,
      nudge_token: "nudge-token-a-abc"
    )
    @grant_b = AccessGrant.create!(
      library: @library,
      token: "grant-token-b-#{SecureRandom.hex(4)}",
      nudge_callback_url: CALLBACK_B,
      nudge_token: "nudge-token-b-xyz"
    )

    # An active grant that never registered a callback — it must be nudged
    # nothing (Req 6.1 targets only grants with a callback URL).
    @grant_no_callback = AccessGrant.create!(
      library: @library,
      token: "grant-token-none-#{SecureRandom.hex(4)}"
    )

    # A revoked grant that *does* carry a callback — it must be skipped because
    # only active, non-revoked grants are nudged (Req 6.1).
    @grant_revoked = AccessGrant.create!(
      library: @library,
      token: "grant-token-revoked-#{SecureRandom.hex(4)}",
      status: :revoked,
      nudge_callback_url: REVOKED_CALLBACK,
      nudge_token: "nudge-token-revoked"
    )
  end

  # --- a catalog change enqueues the nudge (Req 6.1) -------------------------

  test "a catalog change enqueues one CatalogNudgeJob for the changed library" do
    assert_enqueued_with(job: CatalogNudgeJob, args: [ @library.id ]) do
      CatalogVersioning.record_upsert(songs(:mp3_sample))
    end
  end

  # --- performing the job POSTs { nudge_token } to each active callback ------

  test "posts nudge_token to each active grant's callback and nothing to others" do
    stub_a = stub_request(:post, CALLBACK_A).to_return(status: 204)
    stub_b = stub_request(:post, CALLBACK_B).to_return(status: 204)
    stub_revoked = stub_request(:post, REVOKED_CALLBACK).to_return(status: 204)

    CatalogNudgeJob.perform_now(@library.id)

    # Each active grant with a callback receives exactly one POST carrying its
    # own nudge_token as a JSON body (Req 6.1).
    assert_requested :post, CALLBACK_A,
      times: 1,
      headers: { "Content-Type" => "application/json" },
      body: { nudge_token: @grant_a.nudge_token }.to_json
    assert_requested :post, CALLBACK_B,
      times: 1,
      headers: { "Content-Type" => "application/json" },
      body: { nudge_token: @grant_b.nudge_token }.to_json

    # The revoked grant's callback is never contacted, and the callback-less
    # active grant produces no request at all.
    assert_not_requested stub_revoked
  end

  # --- unreachable redeemer is a non-fatal miss (Req 6.3) --------------------

  test "a timing-out callback is swallowed without raising or a retry storm and changes no state" do
    # Grant A times out; grant B is reachable. The miss on A must not stop B and
    # must not surface as a job failure.
    timeout_stub = stub_request(:post, CALLBACK_A).to_timeout
    ok_stub = stub_request(:post, CALLBACK_B).to_return(status: 204)

    version_before = @library.reload.catalog_version
    changes_before = CatalogChange.where(library: @library).count
    grant_a_before = @grant_a.reload.attributes

    assert_nothing_raised do
      perform_enqueued_jobs do
        CatalogNudgeJob.perform_later(@library.id)
      end
    end

    # No retry storm: the failed callback is attempted exactly once, and the
    # reachable one still received its nudge.
    assert_requested timeout_stub, times: 1
    assert_requested ok_stub, times: 1

    # The failed delivery enqueued no follow-up work.
    assert_no_enqueued_jobs

    # The Catalog is unchanged by the failed delivery (Req 6.3).
    assert_equal version_before, @library.reload.catalog_version
    assert_equal changes_before, CatalogChange.where(library: @library).count

    # The Access_Grant is unchanged by the failed delivery (Req 6.3).
    assert_equal grant_a_before, @grant_a.reload.attributes
  end

  test "a connection-refused callback is swallowed without raising or a retry storm" do
    refused_stub = stub_request(:post, CALLBACK_A).to_raise(Errno::ECONNREFUSED)
    ok_stub = stub_request(:post, CALLBACK_B).to_return(status: 204)

    grant_a_before = @grant_a.reload.attributes

    assert_nothing_raised do
      CatalogNudgeJob.perform_now(@library.id)
    end

    # A single attempt per grant — the unreachable redeemer is not retried, and
    # the reachable redeemer is still nudged.
    assert_requested refused_stub, times: 1
    assert_requested ok_stub, times: 1

    # The unreachable delivery left the Access_Grant untouched (Req 6.3).
    assert_equal grant_a_before, @grant_a.reload.attributes
  end
end
