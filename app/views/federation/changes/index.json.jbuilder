json.catalog_version @result.catalog_version
json.full_sync_required @result.full_sync_required

# Each entry is an upsert (created or metadata-updated item, carrying its
# hosting-side id, type, metadata, and associations — Req 3.4) or a deletion
# (a removed item, carrying only its hosting-side id and type — Req 3.5).
# Upserts reuse the exact jbuilder shapes local browsing produces so the mirror
# receives the identical field set.
json.changes @result.changes do |change|
  json.change_type change.change_type
  json.item_type change.item_type
  json.id change.id

  if change.change_type == "upsert"
    case change.item_type
    when "song"
      json.merge! song_json_builder(change.record)
    when "album"
      json.partial! "albums/album", album: change.record
    when "artist"
      json.partial! "artists/artist", artist: change.record
    end
  end
end
