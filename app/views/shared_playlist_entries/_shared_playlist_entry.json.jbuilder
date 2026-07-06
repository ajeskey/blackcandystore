# Client-agnostic Shared_Playlist_Entry representation (Req 9.4). Carries only
# the entry's ordering and adder attribution (Req 5.12, 6.3) plus the referenced
# `song_id` — deliberately NO file path, download, or export field, since a
# Guest is limited to streaming and adding individual Songs (Req 5.7).
json.id shared_playlist_entry.id
json.shared_playlist_id shared_playlist_entry.shared_playlist_id
json.song_id shared_playlist_entry.song_id
json.position shared_playlist_entry.position
json.added_by_guest_id shared_playlist_entry.added_by_guest_id
json.added_by_user_id shared_playlist_entry.added_by_user_id
json.guest_display_name shared_playlist_entry.guest_display_name
json.adder_name shared_playlist_entry.adder_name
