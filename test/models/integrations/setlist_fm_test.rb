# frozen_string_literal: true

require "test_helper"

class Integrations::SetlistFmTest < ActiveSupport::TestCase
  setup do
    @client = Integrations::SetlistFm.new("fake-key")
    @album = albums(:album1) # artist "artist1"
    @artist_response = {
      artist: [ { mbid: "mbid-123", name: "artist1" } ]
    }
    @setlists_response = {
      setlist: [
        {
          eventDate: "10-06-2023",
          venue: { name: "Wembley", city: { name: "London" } },
          tour: { name: "World Tour" },
          sets: { set: [ { song: [ { name: "One" }, { name: "Two" } ] } ] }
        }
      ]
    }
  end

  def stub_artist_search
    stub_request(:get, "https://api.setlist.fm/rest/1.0/search/artists")
      .with(headers: { "x-api-key" => "fake-key" }, query: hash_including("artistName" => "artist1"))
      .to_return(body: @artist_response.to_json, status: 200)
  end

  def stub_setlists
    stub_request(:get, "https://api.setlist.fm/rest/1.0/artist/mbid-123/setlists")
      .with(headers: { "x-api-key" => "fake-key" })
      .to_return(body: @setlists_response.to_json, status: 200)
  end

  test "raises when no API key is configured" do
    assert_raises(Integrations::SetlistFm::MissingApiKey) do
      Integrations::SetlistFm.new(nil)
    end
  end

  test "search_artist resolves a name to an MBID" do
    stub_artist_search

    assert_equal({ mbid: "mbid-123", name: "artist1" }, @client.search_artist("artist1"))
  end

  test "validate_live_album returns a verified summary with venue and song count" do
    stub_artist_search
    stub_setlists

    summary = @client.validate_live_album(@album)

    assert_equal "setlist_fm", summary[:provider]
    assert summary[:verified]
    assert_equal "mbid-123", summary[:mbid]
    assert_equal "Wembley", summary[:venue]
    assert_equal "London", summary[:city]
    assert_equal "10-06-2023", summary[:event_date]
    assert_equal 2, summary[:song_count]
  end

  test "validate_live_album reports not verified when the artist is unknown" do
    stub_request(:get, "https://api.setlist.fm/rest/1.0/search/artists")
      .with(query: hash_including("artistName" => "artist1"))
      .to_return(body: { artist: [] }.to_json, status: 200)

    summary = @client.validate_live_album(@album)

    assert_equal false, summary[:verified]
  end
end
