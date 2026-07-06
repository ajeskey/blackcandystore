# Metadata enrichment (music, audiobooks, live music)

_(Store)_ Black Candy Store enriches your library with cover art and validated
metadata from external providers. It always **identifies content from the files
and directory first** (embedded tags: artist, album, genre, track names), then
uses the right provider to **validate and enrich** what it found.

## How content is identified

`ContentClassifier` reads the tags Black Candy already extracted during
scanning and classifies each album as one of:

| Kind | Signal (from tags) | Provider |
| --- | --- | --- |
| **Audiobook** | genre matches `audiobook` / `spoken word` / `audio drama` | Open Library |
| **Live** | genre matches `live` / `concert` / `bootleg`, or the album/track name looks like "Live at …", "… (Live)" | setlist.fm |
| **Music** | anything else (the default) | Discogs |

Classification is a pure, offline heuristic — no network calls — and falls back
to **music** when tags are ambiguous, so ordinary libraries behave exactly as
before.

## Providers

### Open Library (audiobooks) — no key required

The Goodreads API was retired (Goodreads stopped issuing keys in December 2020),
so Black Candy Store uses **[Open Library](https://openlibrary.org)** for book /
audiobook enrichment. It's free and needs no API key. For an audiobook album it
searches by title + author and stores the validated work: **author(s), first
publication year, work key**, and attaches a **cover** when one is missing.

> The provider is isolated behind `Integrations::OpenLibrary`, so it can be
> swapped for Google Books or Hardcover later without touching the pipeline.

### setlist.fm (live music) — API key required

**[setlist.fm](https://api.setlist.fm/)** validates that a recording is a real
concert and supplies the **setlist, venue, city, event date, and tour**. Set an
API key in **Settings → Server / Integration** (or the `setlistfm_api_key`
setting) to enable it. Lookups resolve the artist name to a MusicBrainz id, then
fetch that artist's setlists; the matched event is stored on the album and shown
with a "Setlist Verified" badge.

**Licensing:** the setlist.fm API is **free for non-commercial use** and
requires attribution. If you run Black Candy Store commercially, review
setlist.fm's terms and obtain appropriate permission. setlist.fm does not
provide cover art — live-album covers still come from embedded art or Discogs.

### Discogs (music) — token required

Unchanged from upstream Black Candy: set a Discogs token to fetch artist and
album cover art for ordinary music.

## Where enrichment is stored and shown

Enrichment is persisted in a provider-agnostic JSON column on the album
(`albums.enrichment`) and surfaced on the album page: author + year for
audiobooks, and a "Setlist Verified" badge with venue/date for live shows.

## Enabling

- **Audiobooks:** nothing to configure — Open Library works out of the box.
- **Live music:** set `setlistfm_api_key` in Settings.
- **Music:** set `discogs_token` in Settings (unchanged).

Enrichment runs during media sync for content that lacks cover art, routed to
the provider matching each album's classification. Each provider is independent
— enabling one does not require the others.
