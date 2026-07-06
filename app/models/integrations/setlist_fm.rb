# frozen_string_literal: true

# setlist.fm metadata provider for live music (api.setlist.fm).
#
# setlist.fm validates that a recording is a real concert and supplies the
# event's setlist, venue, city, date, and tour. It is free for NON-COMMERCIAL
# use and requires an API key (sent in the `x-api-key` header) plus attribution;
# the key is configured via Setting.setlistfm_api_key.
#
# Lookups are keyed on MusicBrainz artist ids (MBID). Given only the artist name
# Black Candy read from the file, this client first resolves the artist to an
# MBID via search, then fetches that artist's setlists. `validate_live_album`
# returns a structured, persistable summary used to enrich a live Album.
class Integrations::SetlistFm < Integrations::Service
  base_uri "https://api.setlist.fm/rest/1.0"

  # Raised when no API key is configured; callers skip enrichment gracefully.
  class MissingApiKey < StandardError; end

  def initialize(api_key = Setting.setlistfm_api_key)
    raise MissingApiKey, "setlist.fm API key is not configured" if api_key.blank?

    self.class.headers "x-api-key" => api_key, "Accept" => "application/json"
  end

  # The first matching artist for a name, as `{ mbid:, name: }`, or nil.
  def search_artist(name)
    return if name.blank?

    json = request("/search/artists", { query: { artistName: name, sort: "relevance" } })
    artist = json&.dig(:artist)&.first
    return unless artist.present?

    { mbid: artist[:mbid], name: artist[:name] }
  end

  # The setlists for an artist MBID (first page), or an empty array.
  def artist_setlists(mbid)
    return [] if mbid.blank?

    json = request("/artist/#{mbid}/setlists")
    Array(json&.dig(:setlist))
  end

  # Validate and summarize a live Album against setlist.fm. Returns a persistable
  # hash marking whether the artist (and a concert) was confirmed, plus the most
  # recent event's venue/date/song-count, or a not-verified marker when the
  # artist cannot be resolved.
  def validate_live_album(album)
    artist = search_artist(album.artist&.name)
    return { provider: "setlist_fm", verified: false } if artist.nil?

    setlist = artist_setlists(artist[:mbid]).first

    {
      provider: "setlist_fm",
      verified: setlist.present?,
      mbid: artist[:mbid],
      artist: artist[:name],
      event_date: setlist&.dig(:eventDate),
      venue: setlist&.dig(:venue, :name),
      city: setlist&.dig(:venue, :city, :name),
      tour: setlist&.dig(:tour, :name),
      song_count: song_count(setlist)
    }.compact
  end

  private

  # Total songs across every set in a setlist (encores included).
  def song_count(setlist)
    return if setlist.nil?

    Array(setlist.dig(:sets, :set)).sum { |set| Array(set[:song]).size }
  end
end
