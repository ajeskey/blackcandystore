json.libraries @libraries, partial: "libraries/library", as: :library
json.active_library_id @active_library&.id

# The current Active_Library's content is returned alongside the library list
# so a multi-library client can render both in one round trip (Req 3.8).
json.active_content do
  json.albums @albums, partial: "albums/album", as: :album
  json.artists @artists, partial: "artists/artist", as: :artist
  json.songs @songs, partial: "songs/song", as: :song
end
