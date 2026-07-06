# frozen_string_literal: true

# A Shared_Playlist is the collaborative, ordered collection of Songs that the
# Host and admitted Guests add to within a Party_Session or a Co_Listen_Session
# (polymorphic `sessionable`). It is retained after the session ends so the Host
# can review it (Req 12.3).
class SharedPlaylist < ApplicationRecord
  belongs_to :sessionable, polymorphic: true

  # Entries are ordered by `position` (Req 6.3). Destroying the playlist removes
  # its entries.
  has_many :entries,
    -> { order(:position) },
    class_name: "SharedPlaylistEntry",
    inverse_of: :shared_playlist,
    dependent: :destroy

  # Songs in playlist order. `song_id` is stored as a plain integer (a shared
  # Song may live on a Remote_Library), so this returns the ordered ids rather
  # than joined Song records.
  def ordered_song_ids
    entries.pluck(:song_id)
  end
end
