# frozen_string_literal: true

require "test_helper"

# Unit tests for SharedPlaylistEntry (Req 5.12, 6.3).
#
# Covers acts_as_list position ordering within a Shared_Playlist (Req 6.3), the
# adder attribution columns and the single-adder validation (Req 5.12), and the
# attribution helpers.
class SharedPlaylistEntryTest < ActiveSupport::TestCase
  setup do
    @host = users(:admin)
    @party = PartySession.create!(user: @host)
    @playlist = SharedPlaylist.create!(sessionable: @party)
  end

  def build_entry(**attrs)
    SharedPlaylistEntry.new({ shared_playlist: @playlist, song_id: 1, added_by_user: @host }.merge(attrs))
  end

  # --- validation: song presence --------------------------------------------

  test "requires a song_id" do
    entry = build_entry(song_id: nil)

    assert_not entry.valid?
    assert_includes entry.errors.attribute_names, :song_id
  end

  test "requires a shared_playlist" do
    entry = build_entry(shared_playlist: nil)

    assert_not entry.valid?
    assert_includes entry.errors.attribute_names, :shared_playlist
  end

  # --- attribution: single adder (Req 5.12) ----------------------------------

  test "is valid when attributed to a host only" do
    entry = build_entry(added_by_user: @host, added_by_guest_id: nil)

    assert entry.valid?, entry.errors.full_messages.to_sentence
  end

  test "is valid when attributed to a guest only" do
    entry = build_entry(added_by_user: nil, added_by_guest_id: 42, guest_display_name: "DJ Guest")

    assert entry.valid?, entry.errors.full_messages.to_sentence
  end

  test "is invalid when attributed to both a guest and a host" do
    entry = build_entry(added_by_user: @host, added_by_guest_id: 42)

    assert_not entry.valid?
    assert_includes entry.errors[:base], "entry cannot be attributed to both a guest and a host"
  end

  test "is invalid when attributed to neither a guest nor a host" do
    entry = build_entry(added_by_user: nil, added_by_guest_id: nil)

    assert_not entry.valid?
    assert_includes entry.errors[:base], "entry must be attributed to a guest or a host"
  end

  test "persists the guest attribution columns" do
    entry = build_entry(added_by_user: nil, added_by_guest_id: 7, guest_display_name: "Alex")
    entry.save!

    reloaded = entry.reload
    assert_equal 7, reloaded.added_by_guest_id
    assert_nil reloaded.added_by_user_id
    assert_equal "Alex", reloaded.guest_display_name
    assert reloaded.added_by_guest?
  end

  test "added_by_guest? is false for a host-added entry" do
    entry = build_entry(added_by_user: @host, added_by_guest_id: nil)

    assert_not entry.added_by_guest?
  end

  # --- attribution helper: adder_name (Req 5.12) -----------------------------

  test "adder_name returns the host email for a host-added entry" do
    entry = build_entry(added_by_user: @host, added_by_guest_id: nil)

    assert_equal @host.email, entry.adder_name
  end

  test "adder_name returns the guest display name for a guest-added entry" do
    entry = build_entry(added_by_user: nil, added_by_guest_id: 7, guest_display_name: "Alex")

    assert_equal "Alex", entry.adder_name
  end

  test "adder_name falls back to a generic guest label when the display name is blank" do
    entry = build_entry(added_by_user: nil, added_by_guest_id: 7, guest_display_name: nil)

    assert_equal "Guest", entry.adder_name
  end

  # --- ordering via acts_as_list (Req 6.3) -----------------------------------

  test "assigns contiguous positions in creation order" do
    a = @playlist.entries.create!(song_id: 1, added_by_user: @host)
    b = @playlist.entries.create!(song_id: 2, added_by_user: @host)
    c = @playlist.entries.create!(song_id: 3, added_by_user: @host)

    assert_equal [ 1, 2, 3 ], [ a, b, c ].map { |e| e.reload.position }
  end

  test "reordering an entry shifts the others to keep positions contiguous" do
    a = @playlist.entries.create!(song_id: 1, added_by_user: @host)
    b = @playlist.entries.create!(song_id: 2, added_by_user: @host)
    c = @playlist.entries.create!(song_id: 3, added_by_user: @host)

    # Move the last entry to the top of the list.
    c.insert_at(1)

    assert_equal [ c.id, a.id, b.id ], @playlist.reload.entries.map(&:id)
    assert_equal [ 1, 2, 3 ], @playlist.entries.map(&:position)
  end

  test "removing an entry closes the gap in positions" do
    a = @playlist.entries.create!(song_id: 1, added_by_user: @host)
    b = @playlist.entries.create!(song_id: 2, added_by_user: @host)
    c = @playlist.entries.create!(song_id: 3, added_by_user: @host)

    b.destroy

    assert_equal [ a.id, c.id ], @playlist.reload.entries.map(&:id)
    assert_equal [ 1, 2 ], @playlist.entries.map(&:position)
  end

  test "positions are scoped per shared_playlist" do
    other_party = PartySession.create!(user: @host)
    other_playlist = SharedPlaylist.create!(sessionable: other_party)

    first = @playlist.entries.create!(song_id: 1, added_by_user: @host)
    other_first = other_playlist.entries.create!(song_id: 1, added_by_user: @host)

    # Each playlist numbers its own entries from the top independently.
    assert_equal 1, first.reload.position
    assert_equal 1, other_first.reload.position
  end
end
