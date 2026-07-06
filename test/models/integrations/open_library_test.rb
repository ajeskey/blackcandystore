# frozen_string_literal: true

require "test_helper"

class Integrations::OpenLibraryTest < ActiveSupport::TestCase
  setup do
    @client = Integrations::OpenLibrary.new
    @album = albums(:album1) # name "album1", artist "artist1"
    @cover_binary = file_fixture("cover_image.jpg").read.force_encoding("BINARY").strip
    @search_response = {
      docs: [
        {
          key: "/works/OL123W",
          title: "album1",
          author_name: [ "artist1" ],
          first_publish_year: 1999,
          cover_i: 42,
          edition_count: 3
        }
      ]
    }
  end

  def stub_search
    stub_request(:get, "https://openlibrary.org/search.json")
      .with(query: hash_including("title" => "album1", "author" => "artist1"))
      .to_return(body: @search_response.to_json, status: 200)
  end

  test "book_metadata returns validated book details" do
    stub_search

    metadata = @client.book_metadata(@album)

    assert_equal "open_library", metadata[:provider]
    assert_equal "/works/OL123W", metadata[:work_key]
    assert_equal [ "artist1" ], metadata[:authors]
    assert_equal 1999, metadata[:first_publish_year]
  end

  test "cover_image downloads the cover by cover id" do
    stub_search
    stub_request(:get, "https://covers.openlibrary.org/b/id/42-L.jpg")
      .to_return(body: @cover_binary, status: 200, headers: { "Content-Type" => "image/jpeg" })

    resource = @client.cover_image(@album)

    assert_equal @cover_binary, resource[:io].read.force_encoding("BINARY").strip
    assert_equal "image/jpeg", resource[:content_type]
  end

  test "returns nil when there is no match" do
    stub_request(:get, "https://openlibrary.org/search.json")
      .with(query: hash_including("title" => "album1"))
      .to_return(body: { docs: [] }.to_json, status: 200)

    assert_nil @client.book_metadata(@album)
    assert_nil @client.cover_image(@album)
  end

  test "raises too many requests when rate limited" do
    stub_request(:get, "https://openlibrary.org/search.json")
      .with(query: hash_including("title" => "album1"))
      .to_return(status: 429)

    assert_raises(Integrations::Service::TooManyRequests) do
      @client.book_metadata(@album)
    end
  end
end
