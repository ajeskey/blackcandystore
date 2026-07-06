# The Shared_Playlist's entries in playlist order (Req 6.3). Individual-song
# entries only; no bulk file-path/download data is exposed (Req 5.7).
json.shared_playlist_id @shared_playlist.id
json.entries @entries, partial: "shared_playlist_entries/shared_playlist_entry", as: :shared_playlist_entry
