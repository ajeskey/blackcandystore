# frozen_string_literal: true

# Open Library metadata provider for audiobooks / books (openlibrary.org).
#
# Replaces the retired Goodreads API for book identification and enrichment. It
# is free and needs no API key. Given the title (album name) and author (artist
# name) Black Candy already read from the file/directory, it searches Open
# Library, then returns cover art and book metadata (author, first publication
# year, work key, description) for validation and enrichment.
#
# Mirrors Integrations::Discogs so it plugs into the same cover-art job shape:
# `cover_image(album)` returns a download descriptor or nil.
class Integrations::OpenLibrary < Integrations::Service
  base_uri "https://openlibrary.org"

  # Cover images are served from a separate host, keyed by cover id.
  COVERS_BASE_URI = "https://covers.openlibrary.org"

  # Return a cover-image download descriptor for an audiobook Album, or nil when
  # no confident match is found.
  def cover_image(album)
    doc = best_match(album)
    cover_id = doc&.dig(:cover_i)
    return unless cover_id.present?

    download_image("#{COVERS_BASE_URI}/b/id/#{cover_id}-L.jpg")
  end

  # Return structured book metadata for an Album, or nil when there is no match.
  # Used to validate identity and enrich the catalog (author, year, work key).
  def book_metadata(album)
    doc = best_match(album)
    return unless doc.present?

    {
      provider: "open_library",
      work_key: doc[:key],
      title: doc[:title],
      authors: Array(doc[:author_name]),
      first_publish_year: doc[:first_publish_year],
      cover_id: doc[:cover_i],
      edition_count: doc[:edition_count]
    }.compact
  end

  private

  # The best search result for this Album's title + author, or nil. The search
  # is title-scoped and author-filtered so a common title does not match the
  # wrong book.
  def best_match(album)
    query = { title: album.name, limit: 1, fields: SEARCH_FIELDS.join(",") }
    query[:author] = album.artist.name if named_author?(album)

    json = request("/search.json", { query: query })
    json&.dig(:docs)&.first
  end

  SEARCH_FIELDS = %w[key title author_name first_publish_year cover_i edition_count].freeze

  def named_author?(album)
    author = album.artist&.name
    author.present? && author != Artist::UNKNOWN_NAME && author != Artist::VARIOUS_NAME
  end
end
