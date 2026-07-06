# frozen_string_literal: true

# Validates and enriches a live Album from setlist.fm: resolves the artist,
# confirms a concert exists, and stores the event's venue, date, tour, and song
# count. The album is identified as live from directory tags by
# ContentClassifier before this job is enqueued. Skips gracefully when no
# setlist.fm API key is configured.
class ValidateLiveAlbumFromSetlistFmJob < ApplicationJob
  retry_on Integrations::Service::TooManyRequests, wait: 1.minute, attempts: :unlimited
  queue_as :default

  def perform(album)
    client = Integrations::SetlistFm.new

    summary = client.validate_live_album(album)
    album.update!(enrichment: summary) if summary.present?
  rescue Integrations::SetlistFm::MissingApiKey
    # No key configured — nothing to enrich; leave the album unchanged.
    nil
  end
end
