# frozen_string_literal: true

require "test_helper"

class ValidateLiveAlbumFromSetlistFmJobTest < ActiveSupport::TestCase
  setup do
    @album = albums(:album1)
  end

  FakeClient = Struct.new(:summary) do
    def validate_live_album(_album) = summary
  end

  test "stores the setlist.fm validation summary" do
    fake = FakeClient.new({ provider: "setlist_fm", verified: true, venue: "Wembley" })

    Integrations::SetlistFm.stub(:new, fake) do
      ValidateLiveAlbumFromSetlistFmJob.perform_now(@album)
    end

    assert @album.reload.enrichment["verified"]
    assert_equal "Wembley", @album.enrichment["venue"]
  end

  test "does nothing when no API key is configured" do
    raiser = -> { raise Integrations::SetlistFm::MissingApiKey }

    Integrations::SetlistFm.stub(:new, raiser) do
      assert_nothing_raised do
        ValidateLiveAlbumFromSetlistFmJob.perform_now(@album)
      end
    end

    assert @album.reload.enrichment.blank?
  end
end
