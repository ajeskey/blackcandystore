# frozen_string_literal: true

require "test_helper"

class EnrichAudiobookFromOpenLibraryJobTest < ActiveSupport::TestCase
  setup do
    @album = albums(:album1)
  end

  # Minimal stand-in for the Open Library client.
  FakeClient = Struct.new(:metadata, :image) do
    def book_metadata(_album) = metadata
    def cover_image(_album) = image
  end

  test "stores book metadata returned by Open Library" do
    fake = FakeClient.new({ provider: "open_library", authors: [ "Some Author" ], first_publish_year: 2010 }, nil)

    Integrations::OpenLibrary.stub(:new, fake) do
      EnrichAudiobookFromOpenLibraryJob.perform_now(@album)
    end

    assert_equal "open_library", @album.reload.enrichment["provider"]
    assert_equal [ "Some Author" ], @album.enrichment["authors"]
  end

  test "leaves enrichment unset when there is no match" do
    fake = FakeClient.new(nil, nil)

    Integrations::OpenLibrary.stub(:new, fake) do
      EnrichAudiobookFromOpenLibraryJob.perform_now(@album)
    end

    assert @album.reload.enrichment.blank?
  end
end
