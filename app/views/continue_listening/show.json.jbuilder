json.items @positions do |position|
  song = position.song
  album = song.album

  json.song_id song.id
  json.song_name song.name
  json.album_name album.name

  # Mirror the album-page audiobook enrichment display: expose author and
  # first-publish-year only when the Album is an Audiobook with stored
  # enrichment (Req 10.3); null otherwise so clients get a stable shape.
  if album.audiobook? && album.enriched?
    json.album_enrichment do
      json.authors Array(album.enrichment["authors"])
      json.first_publish_year album.enrichment["first_publish_year"]
    end
  else
    json.album_enrichment nil
  end

  json.position_seconds position.position_seconds
  json.duration song.duration
  json.updated_at position.updated_at
end
