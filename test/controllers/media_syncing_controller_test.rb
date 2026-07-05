# frozen_string_literal: true

require "test_helper"

class MediaSyncingControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  test "should scan every local library" do
    login users(:admin)

    assert_enqueued_jobs Library.local.count, only: LibraryScanJob do
      post media_syncing_url
    end
  end

  test "should scan only the requested library when a library_id is given" do
    login users(:admin)
    library = libraries(:secondary_library)

    assert_enqueued_with(job: LibraryScanJob, args: [ library.id ]) do
      post media_syncing_url, params: { library_id: library.id }
    end
  end

  test "should only admin can sync media" do
    login

    post media_syncing_url
    assert_response :forbidden
  end

  test "should not sync media when a library is already syncing" do
    login users(:admin)
    libraries(:default_library).update!(scan_state: :syncing)

    assert_no_enqueued_jobs only: LibraryScanJob do
      post media_syncing_url
    end
  end
end
