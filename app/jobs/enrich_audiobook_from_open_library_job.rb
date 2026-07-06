# frozen_string_literal: true

require "open-uri"

# Enriches an audiobook Album from Open Library: attaches a cover when missing
# and stores validated book metadata (author, publication year, work key). The
# album is identified from directory tags by ContentClassifier before this job
# is enqueued, so this job only runs for audiobook-classified content.
class EnrichAudiobookFromOpenLibraryJob < ApplicationJob
  retry_on Integrations::Service::TooManyRequests, wait: 1.minute, attempts: :unlimited
  queue_as :default

  def perform(album)
    client = Integrations::OpenLibrary.new

    metadata = client.book_metadata(album)
    album.update!(enrichment: metadata) if metadata.present?

    return if album.has_cover_image?

    image_resource = client.cover_image(album)
    album.cover_image.attach(image_resource) if image_resource.present?
  end
end
