# frozen_string_literal: true

require "test_helper"

# Property-based test for Property 7 of the remote-library-mirror-sync feature.
#
# Design property (remote-library-mirror-sync, Property 7):
#   Deletions propagate and orphaned albums/artists are cleaned up exactly when
#   unreferenced (Req 5.1, 5.2).
#
# `CatalogSync.apply(connection, changes)` reconciles a Catalog_Mirror in place.
# For a deletion change it removes the mirrored item identified by the pairing
# of the connection's remote Library and the item's hosting-side id (Req 5.1),
# then reuses `Media.clean_up` scoped to that remote Library to drop any album
# or artist that no longer has a song associated with it in the same mirror
# (Req 5.2).
#
# This test materializes a Catalog_Mirror (a `kind: remote` Library reached
# through a Library_Connection) holding artists, albums, and songs that each
# carry their hosting-side `remote_*_id`, with every song wired to an album and
# an artist that share the same artist. It then generates a set of song-deletion
# Catalog_Changes (a random subset of the mirror's songs, some of which orphan
# their album/artist, plus a few phantom deletions for ids not in the mirror to
# exercise the no-op/idempotent path) and applies them.
#
# The expected mirror is computed independently from the deletion set:
#   * a song survives iff it was not deleted (Req 5.1), keyed by
#     (Library_Connection, remote_song_id);
#   * an album survives iff at least one surviving song still references it, and
#   * an artist survives iff at least one surviving song still references it
#     (Req 5.2 — removed if and only if unreferenced).
#
# A second, independent Catalog_Mirror (another connection) is built with the
# SAME hosting-side ids so the test also asserts a deletion scoped to one
# connection never touches the other connection's mirror — the "in the same
# mirror" clause of the property (Req 5.1, per-connection identity).
class DeletionPropagationPropertyTest < ActiveSupport::TestCase
  # Hosting-side ids never assigned to a real mirrored row, used for phantom
  # deletions that must be no-ops.
  PHANTOM_ID_BASE = 9_000_000

  setup do
    @user = users(:admin)
    @seq = 0
  end

  # Feature: remote-library-mirror-sync, Property 7: Deletions propagate and orphaned albums/artists are cleaned up exactly when unreferenced
  test "song deletions remove the identified mirrored song and clean up albums/artists exactly when unreferenced" do
    check_property(iterations: 100) do
      # Runs inside a Rantly instance, so range/boolean are called on `self`.
      artist_count = range(1, 3)
      # Each album is owned by one of the artists; only albums referenced by a
      # song are materialized, so no pre-existing orphans exist.
      album_to_artist = Array.new(range(1, 4)) { range(0, artist_count - 1) }
      # Each song references one album (and inherits that album's artist).
      song_to_album = Array.new(range(1, 8)) { range(0, album_to_artist.size - 1) }
      # Which songs to delete.
      delete_flags = Array.new(song_to_album.size) { boolean }
      # A few phantom deletions for ids that are not in the mirror.
      phantom_count = range(0, 3)

      [ artist_count, album_to_artist, song_to_album, delete_flags, phantom_count ]
    end.check do |(artist_count, album_to_artist, song_to_album, delete_flags, phantom_count)|
      reset_state

      # Only materialize albums (and their artists) that a song references, so
      # the mirror starts with zero orphans and the "no deletions" case stays
      # consistent with the expected computation below.
      used_album_indices = song_to_album.uniq
      used_artist_indices = used_album_indices.map { |a| album_to_artist[a] }.uniq

      # --- Build the target mirror (connection under test). -----------------
      target_conn = create_connection
      target_lib = create_remote_library(target_conn)
      build_mirror(target_lib, artist_count, album_to_artist, song_to_album, used_album_indices, used_artist_indices)

      # --- Build an independent mirror sharing the SAME hosting-side ids. ----
      other_conn = create_connection
      other_lib = create_remote_library(other_conn)
      build_mirror(other_lib, artist_count, album_to_artist, song_to_album, used_album_indices, used_artist_indices)

      other_song_ids_before = other_lib.songs.pluck(:remote_song_id).sort
      other_album_ids_before = other_lib.albums.pluck(:remote_album_id).sort
      other_artist_ids_before = other_lib.artists.pluck(:remote_artist_id).sort

      # --- Generate and apply the deletion change set. ----------------------
      deleted_song_indices = song_to_album.each_index.select { |i| delete_flags[i] }
      changes =
        deleted_song_indices.map { |i| deletion_change(remote_song_id(i)) } +
        Array.new(phantom_count) { |k| deletion_change(PHANTOM_ID_BASE + k + 1) }

      CatalogSync.apply(target_conn, changes)

      # --- Expected surviving mirror, computed independently. ---------------
      surviving_song_indices = song_to_album.each_index.reject { |i| delete_flags[i] }
      expected_song_ids = surviving_song_indices.map { |i| remote_song_id(i) }.sort
      surviving_album_indices = surviving_song_indices.map { |i| song_to_album[i] }.uniq
      expected_album_ids = surviving_album_indices.map { |a| remote_album_id(a) }.sort
      expected_artist_ids =
        surviving_album_indices.map { |a| remote_artist_id(album_to_artist[a]) }.uniq.sort

      target_lib.reload

      # (Req 5.1) The mirrored song identified by (connection, remote_song_id)
      # is removed iff it was deleted; every other song survives.
      assert_equal expected_song_ids, target_lib.songs.pluck(:remote_song_id).sort,
        "surviving mirrored songs must be exactly those not deleted (keyed by remote_song_id)"

      # (Req 5.2) An album/artist is removed if and only if no surviving song is
      # associated with it in the same mirror.
      assert_equal expected_album_ids, target_lib.albums.pluck(:remote_album_id).sort,
        "an album survives iff a surviving song still references it"
      assert_equal expected_artist_ids, target_lib.artists.pluck(:remote_artist_id).sort,
        "an artist survives iff a surviving song still references it"

      # (Req 5.2, explicit iff) Every surviving album/artist is still referenced,
      # and nothing referenced was removed — checked directly against live rows.
      target_lib.albums.each do |album|
        assert album.songs.exists?,
          "a surviving album must still have at least one mirrored song (album remote id #{album.remote_album_id})"
      end
      target_lib.artists.each do |artist|
        assert target_lib.songs.where(artist_id: artist.id).exists?,
          "a surviving artist must still have at least one mirrored song (artist remote id #{artist.remote_artist_id})"
      end

      # (Req 5.1, per-connection identity) The other connection's mirror, which
      # shares the same hosting-side ids, is completely untouched.
      other_lib.reload
      assert_equal other_song_ids_before, other_lib.songs.pluck(:remote_song_id).sort,
        "a deletion scoped to one connection must not remove songs from another connection's mirror"
      assert_equal other_album_ids_before, other_lib.albums.pluck(:remote_album_id).sort,
        "a deletion scoped to one connection must not remove albums from another connection's mirror"
      assert_equal other_artist_ids_before, other_lib.artists.pluck(:remote_artist_id).sort,
        "a deletion scoped to one connection must not remove artists from another connection's mirror"
    end
  end

  private

  def next_seq
    @seq += 1
  end

  # Isolate each iteration: remove all mirror content and connections, keeping
  # only the fixture libraries so the dataset observed is exactly the one built.
  def reset_state
    Song.delete_all
    Album.delete_all
    Artist.delete_all
    fixture_ids = [ libraries(:default_library).id, libraries(:secondary_library).id ]
    Library.where.not(id: fixture_ids).delete_all
    LibraryConnection.delete_all
  end

  def create_connection
    connection = LibraryConnection.new(user: @user, status: "active")
    connection.grant_token = "grant-#{next_seq}"
    connection.save!
    connection
  end

  def create_remote_library(connection)
    Library.create!(name: "Prop7-Remote-#{next_seq}", kind: "remote", library_connection: connection)
  end

  # Stable hosting-side ids derived from generation indices so the two mirrors
  # share identical remote ids.
  def remote_artist_id(index) = index + 1

  def remote_album_id(index) = index + 1

  def remote_song_id(index) = index + 1

  def deletion_change(remote_id)
    { "change_type" => "deletion", "item_type" => "song", "id" => remote_id }
  end

  # Materialize the mirror: only the referenced albums/artists are created, and
  # every song is wired to an album and an artist that share the same artist so
  # "a song is associated with an album" and "a song is associated with an
  # artist" coincide, making orphan cleanup unambiguous.
  def build_mirror(library, artist_count, album_to_artist, song_to_album, used_album_indices, used_artist_indices)
    artists = {}
    used_artist_indices.each do |ai|
      artists[ai] = Artist.create!(
        name: "Artist-#{ai}-#{next_seq}",
        library: library,
        remote_artist_id: remote_artist_id(ai)
      )
    end

    albums = {}
    used_album_indices.each do |al|
      artist = artists[album_to_artist[al]]
      albums[al] = Album.create!(
        name: "Album-#{al}-#{next_seq}",
        artist: artist,
        library: library,
        remote_album_id: remote_album_id(al)
      )
    end

    song_to_album.each_index do |si|
      album = albums[song_to_album[si]]
      Song.create!(
        name: "Song-#{si}-#{next_seq}",
        duration: 100.0 + si,
        tracknum: (si % 12) + 1,
        discnum: 1,
        library: library,
        album: album,
        artist: album.artist,
        remote_song_id: remote_song_id(si)
      )
    end
  end
end
