# frozen_string_literal: true

require "test_helper"

# Property-based test for Property 5 of the remote-library-mirror-sync feature.
#
# Design property (remote-library-mirror-sync, Property 5):
#   For any Catalog_Mirror and any set of Catalog_Changes, applying that set
#   more than once SHALL yield a Catalog_Mirror identical to the one produced by
#   applying it exactly once (Req 8.2, 2.2).
#
# `CatalogSync.apply(connection, changes)` mutates a Remote_Library's
# Catalog_Mirror (`connection.library`) in place to reflect an ordered list of
# Catalog_Changes: upserts create-or-find a Mirrored_Song/Album/Artist keyed on
# the pairing of the Library_Connection and the item's hosting-side identifier
# (`(library_id, remote_*_id)`) and set its metadata/associations, while
# deletions remove the mirrored item by that same pairing and drop any
# album/artist left with no mirrored song.
#
# This test first materializes an arbitrary starting Catalog_Mirror by applying
# a randomly generated base change set, then applies a second randomly generated
# change set once, twice, and three times. It snapshots the mirror after each
# application -- every Mirrored_Song/Album/Artist keyed by its hosting-side id
# together with its metadata and its associations expressed through the
# hosting-side ids of the associated mirrored rows (never the volatile local
# autoincrement id, since an item removed and re-created across applications
# keeps its hosting-side id but takes a new local id; Req 2.2). It then asserts
# the after-once snapshot equals the after-twice and after-thrice snapshots:
# same rows, same metadata, same associations, and therefore the same counts.
#
# Change sets are generated over a small shared pool of hosting-side ids so
# upserts and deletions collide, associations are shared, and deletions produce
# orphaned albums/artists -- exercising the create-or-find idempotence, the
# deletion-is-a-no-op-when-absent idempotence, and the orphan cleanup together.
#
# Names are a canonical function of the hosting-side id ("artist-#{id}",
# "album-#{id}"). This faithfully models a real Changes_Since feed: on the
# Hosting_Server artists are keyed by `(library_id, name)` and albums by
# `(library_id, artist_id, name)`, so a hosting-side id maps to a stable name
# and no two distinct ids share a name. Drawing names independently of ids would
# fabricate a catalog the host could never emit and violate the mirror's
# matching per-library-unique name indexes. Non-identifying metadata (year,
# genre, duration, track/disc numbers, is_various) is drawn freely: within one
# change set the last upsert of an id wins deterministically, so it exercises
# metadata updates without breaking idempotence.
class IdempotentApplyPropertyTest < ActiveSupport::TestCase
  # Small hosting-side id pools so changes reference a shared, colliding id
  # space (upserts overwrite the same rows, deletions hit ids that upserts also
  # target, and associations are shared across items).
  ARTIST_IDS = 3
  ALBUM_IDS = 4
  SONG_IDS = 6

  setup do
    @user = users(:admin)

    # A single Remote_Library reached through an active Library_Connection is
    # the Catalog_Mirror under test. Its content is reset per iteration; the
    # library/connection shells persist.
    @connection = LibraryConnection.create!(
      user: @user,
      server_base_url: "https://remote.example.com",
      remote_library_id: 4242,
      grant_token: "remote-bearer-token",
      status: :active
    )
    @mirror = Library.create!(
      name: "Prop5-Mirror-#{SecureRandom.hex(4)}",
      kind: :remote,
      owner: @user,
      library_connection: @connection
    )
  end

  # Feature: remote-library-mirror-sync, Property 5: Applying the same change set is idempotent
  test "applying the same change set more than once yields a mirror identical to applying it exactly once" do
    check_property(iterations: 100) do
      rng = self # Rantly instance

      # Build one ordered change set over the shared hosting-side id pools:
      # ~60% upserts (of a random song/album/artist) and ~40% deletions.
      build = lambda do
        Array.new(rng.range(0, 10)) do
          if rng.range(0, 9) < 6
            case %w[artist album song][rng.range(0, 2)]
            when "artist"
              artist_id = rng.range(1, ARTIST_IDS)
              {
                "change_type" => "upsert", "item_type" => "artist",
                "id" => artist_id,
                "name" => "artist-#{artist_id}",
                "is_various" => rng.boolean
              }
            when "album"
              album_id = rng.range(1, ALBUM_IDS)
              artist_id = rng.range(1, ARTIST_IDS)
              {
                "change_type" => "upsert", "item_type" => "album",
                "id" => album_id,
                "name" => "album-#{album_id}",
                "year" => rng.range(1960, 2024),
                "genre" => "genre-#{rng.range(1, 4)}",
                "artist_id" => artist_id,
                "artist_name" => "artist-#{artist_id}"
              }
            else
              song_id = rng.range(1, SONG_IDS)
              album_id = rng.range(1, ALBUM_IDS)
              artist_id = rng.range(1, ARTIST_IDS)
              {
                "change_type" => "upsert", "item_type" => "song",
                "id" => song_id,
                "name" => "song-#{song_id}",
                "duration" => rng.range(30, 300),
                "tracknum" => rng.range(1, 20),
                "discnum" => rng.range(1, 3),
                "album_id" => album_id,
                "album_name" => "album-#{album_id}",
                "artist_id" => artist_id,
                "artist_name" => "artist-#{artist_id}"
              }
            end
          else
            item_type = %w[artist album song][rng.range(0, 2)]
            pool = { "artist" => ARTIST_IDS, "album" => ALBUM_IDS, "song" => SONG_IDS }[item_type]
            { "change_type" => "deletion", "item_type" => item_type, "id" => rng.range(1, pool) }
          end
        end
      end

      # A base set materializes an arbitrary starting Catalog_Mirror; the second
      # set is the one applied repeatedly.
      [ build.call, build.call ]
    end.check do |(base_changes, changes)|
      # Isolate each iteration: reset the mirror to empty before rebuilding it.
      reset_mirror

      # Establish an arbitrary starting Catalog_Mirror (M0).
      CatalogSync.apply(@connection, base_changes)

      # Apply the change set once, twice, three times, snapshotting between.
      CatalogSync.apply(@connection, changes)
      after_once = snapshot_mirror

      CatalogSync.apply(@connection, changes)
      after_twice = snapshot_mirror

      CatalogSync.apply(@connection, changes)
      after_thrice = snapshot_mirror

      # Idempotence: applying the same set again is a no-op on the mirror.
      assert_equal after_once, after_twice,
        "applying the change set twice produced a different mirror than applying it once"
      assert_equal after_once, after_thrice,
        "applying the change set three times produced a different mirror than applying it once"
    end
  end

  private

  # Empty the Catalog_Mirror so each iteration starts from a known baseline.
  # Order (songs, then albums, then artists) respects the association graph.
  def reset_mirror
    Song.where(library_id: @mirror.id).delete_all
    Album.where(library_id: @mirror.id).delete_all
    Artist.where(library_id: @mirror.id).delete_all
  end

  # Capture the mirror's content keyed by hosting-side identifier. Associations
  # are expressed through the associated mirrored row's hosting-side id (not its
  # local autoincrement id), so a row removed and re-created across applications
  # compares equal by identity (Req 2.2). Sorting by hosting-side id makes the
  # comparison order-independent.
  def snapshot_mirror
    songs = Song.where(library_id: @mirror.id).map do |song|
      {
        remote_id: song.remote_song_id,
        name: song.name,
        duration: song.duration,
        tracknum: song.tracknum,
        discnum: song.discnum,
        album_remote_id: song.album&.remote_album_id,
        artist_remote_id: song.artist&.remote_artist_id
      }
    end.sort_by { |row| row[:remote_id] }

    albums = Album.where(library_id: @mirror.id).map do |album|
      {
        remote_id: album.remote_album_id,
        name: album.name,
        year: album.year,
        genre: album.genre,
        artist_remote_id: album.artist&.remote_artist_id
      }
    end.sort_by { |row| row[:remote_id] }

    artists = Artist.where(library_id: @mirror.id).map do |artist|
      {
        remote_id: artist.remote_artist_id,
        name: artist.name,
        various: artist.various
      }
    end.sort_by { |row| row[:remote_id] }

    { songs: songs, albums: albums, artists: artists }
  end
end
