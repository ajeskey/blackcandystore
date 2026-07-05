json.call(album, :id, :name, :year, :genre, :artist_id)
json.artist_name album.artist.name
json.image_urls do
  json.small URI.join(root_url, cover_image_url_for(album, size: :small))
  json.medium URI.join(root_url, cover_image_url_for(album, size: :medium))
  json.large URI.join(root_url, cover_image_url_for(album, size: :large))
end

# Resolve the cover image's Asset_Source and Resolved_Asset_Path at the edge so
# clients treat local and remote artwork the same way (Req 9.2, 9.9).
resolved_asset = PathResolver.new.resolve_asset(album, user: Current.user)
json.asset_source resolved_asset[:asset_source]
json.resolved_asset_path resolved_asset[:resolved_asset_path]
