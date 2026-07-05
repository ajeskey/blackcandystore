json.call(artist, :id, :name)
json.is_various artist.various
json.image_urls do
  json.small URI.join(root_url, cover_image_url_for(artist, size: :small))
  json.medium URI.join(root_url, cover_image_url_for(artist, size: :medium))
  json.large URI.join(root_url, cover_image_url_for(artist, size: :large))
end

# Resolve the cover image's Asset_Source and Resolved_Asset_Path at the edge so
# clients treat local and remote artwork the same way (Req 9.2, 9.9).
resolved_asset = PathResolver.new.resolve_asset(artist, user: Current.user)
json.asset_source resolved_asset[:asset_source]
json.resolved_asset_path resolved_asset[:resolved_asset_path]
