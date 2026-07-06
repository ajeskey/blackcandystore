# frozen_string_literal: true

# A Shared_Playlist_Entry is a single Song placed in a Shared_Playlist, ordered
# by `position` (Req 6.3) and attributed to the participant that added it
# (Req 5.12). Exactly one of `added_by_guest_id` (a Guest) or `added_by_user_id`
# (the Host) identifies the adder; `guest_display_name` snapshots the Guest's
# optional display name at add time so attribution survives later changes.
class SharedPlaylistEntry < ApplicationRecord
  belongs_to :shared_playlist, inverse_of: :entries

  # The Host that added the entry, when added by the Host. `added_by_guest_id`
  # references a Guest but is stored as a plain integer (the `guests` table is
  # managed independently), so no association is declared for it here.
  belongs_to :added_by_user, class_name: "User", optional: true

  # Ordering within the playlist (Req 6.3). Positions are contiguous per
  # playlist and maintained by acts_as_list, matching PlaylistsSong.
  acts_as_list scope: :shared_playlist

  default_scope { order(:position) }

  validates :song_id, presence: true
  validate :attributed_to_a_single_adder

  # True when this entry was added by a Guest rather than the Host.
  def added_by_guest?
    added_by_guest_id.present?
  end

  # Attribution label for the adder: the Guest's display name (falling back to a
  # generic guest label) when a Guest added it, otherwise the Host (Req 5.12).
  def adder_name
    return added_by_user&.email if added_by_user_id.present?

    guest_display_name.presence || "Guest"
  end

  private

  # An entry is attributed to exactly one adder: a Guest or the Host, never both.
  def attributed_to_a_single_adder
    if added_by_guest_id.present? && added_by_user_id.present?
      errors.add(:base, "entry cannot be attributed to both a guest and a host")
    elsif added_by_guest_id.blank? && added_by_user_id.blank?
      errors.add(:base, "entry must be attributed to a guest or a host")
    end
  end
end
