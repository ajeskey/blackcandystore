# frozen_string_literal: true

# Classifies a piece of content as music, an audiobook, or a live recording,
# using the metadata already extracted from the file/directory during scanning
# (Req: identify from the directory first, then validate/enrich externally).
#
# Classification is intentionally a pure, heuristic read over the tags Black
# Candy already has (genre, album/song name) — no network calls. It only picks
# which external provider should later validate and enrich the content:
#
#   :audiobook -> Open Library (book covers, author, publication info)
#   :live      -> setlist.fm (setlist validation, venue, event date)
#   :music     -> Discogs (the existing default)
#
# When tags are ambiguous it falls back to :music, so the existing behavior is
# unchanged for ordinary libraries.
module ContentClassifier
  MUSIC = :music
  AUDIOBOOK = :audiobook
  LIVE = :live

  # Genre tags that mark spoken-word / audiobook content.
  AUDIOBOOK_GENRES = [
    /audio\s?book/i,
    /\bspoken\s?word\b/i,
    /\baudio\s?drama\b/i
  ].freeze

  # Genre tags that mark a live recording.
  LIVE_GENRES = [
    /\blive\b/i,
    /\bconcert\b/i,
    /\bbootleg\b/i
  ].freeze

  # Album/track name patterns that mark a live recording, e.g. "Live at
  # Wembley", "... (Live)", "Live in Tokyo 1994".
  LIVE_NAME_PATTERNS = [
    /\blive\s+at\b/i,
    /\blive\s+in\b/i,
    /\blive\s+from\b/i,
    /\(\s*live\s*\)/i,
    /\[\s*live\s*\]/i,
    /-\s*live\b/i
  ].freeze

  module_function

  # Classify an Album from its tags. Returns :audiobook, :live, or :music.
  def classify_album(album)
    return MUSIC if album.nil?

    classify(genre: album.genre, name: album.name)
  end

  # Classify from raw tag values (used by the classifier tests and by callers
  # that have tags but no persisted Album yet).
  def classify(genre: nil, name: nil)
    return AUDIOBOOK if AUDIOBOOK_GENRES.any? { |pattern| pattern.match?(genre.to_s) }
    return LIVE if LIVE_GENRES.any? { |pattern| pattern.match?(genre.to_s) }
    return LIVE if LIVE_NAME_PATTERNS.any? { |pattern| pattern.match?(name.to_s) }

    MUSIC
  end

  def audiobook?(album)
    classify_album(album) == AUDIOBOOK
  end

  def live?(album)
    classify_album(album) == LIVE
  end
end
