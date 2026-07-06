# frozen_string_literal: true

require "test_helper"

# Unit tests for SharedPlaylist (Req 5.12, 6.3, 12.3).
#
# Covers the polymorphic `sessionable` association integrity (a Shared_Playlist
# belongs to either a Party_Session or a Co_Listen_Session), the position
# ordering of its entries (Req 6.3), and retention of entries independent of
# the session lifecycle (Req 12.3).
class SharedPlaylistTest < ActiveSupport::TestCase
  setup do
    @host = users(:admin)
    @party = PartySession.create!(user: @host)
    @co_listen = CoListenSession.create!(user: @host)
  end

  def build_playlist(sessionable: @party)
    SharedPlaylist.create!(sessionable: sessionable)
  end

  test "belongs to a Party_Session through the polymorphic sessionable" do
    playlist = build_playlist(sessionable: @party)

    assert_equal @party, playlist.sessionable
    assert_equal "PartySession", playlist.sessionable_type
    assert_equal @party.id, playlist.sessionable_id
  end

  test "belongs to a Co_Listen_Session through the polymorphic sessionable" do
    playlist = build_playlist(sessionable: @co_listen)

    assert_equal @co_listen, playlist.sessionable
    assert_equal "CoListenSession", playlist.sessionable_type
  end

  test "is reachable from the session's has_one shared_playlist association" do
    playlist = build_playlist(sessionable: @party)

    assert_equal playlist, @party.reload.shared_playlist
  end

  test "requires a sessionable" do
    playlist = SharedPlaylist.new(sessionable: nil)

    assert_not playlist.valid?
    assert_includes playlist.errors.attribute_names, :sessionable
  end

  test "orders entries by position regardless of insertion order" do
    playlist = build_playlist

    third = playlist.entries.create!(song_id: 3, added_by_user: @host)
    first = playlist.entries.create!(song_id: 1, added_by_user: @host)
    second = playlist.entries.create!(song_id: 2, added_by_user: @host)

    # acts_as_list appends new entries to the bottom, so the ids come back in
    # creation order once ordered by position.
    assert_equal [ third.id, first.id, second.id ], playlist.reload.entries.map(&:id)
    assert_equal [ 1, 2, 3 ], playlist.entries.map(&:position)
  end

  test "ordered_song_ids returns song ids in playlist order" do
    playlist = build_playlist
    playlist.entries.create!(song_id: 30, added_by_user: @host)
    playlist.entries.create!(song_id: 10, added_by_user: @host)
    playlist.entries.create!(song_id: 20, added_by_user: @host)

    assert_equal [ 30, 10, 20 ], playlist.reload.ordered_song_ids
  end

  test "destroying the playlist destroys its entries" do
    playlist = build_playlist
    playlist.entries.create!(song_id: 1, added_by_user: @host)
    playlist.entries.create!(song_id: 2, added_by_user: @host)

    assert_difference -> { SharedPlaylistEntry.count }, -2 do
      playlist.destroy
    end
  end

  test "entries are retained when the backing session ends (Req 12.3)" do
    playlist = build_playlist(sessionable: @party)
    playlist.entries.create!(song_id: 1, added_by_user: @host)

    @party.ended!

    assert_equal 1, playlist.reload.entries.count,
      "ending the session must not remove the retained playlist entries"
  end
end
