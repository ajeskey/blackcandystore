# frozen_string_literal: true

require "test_helper"

# Property-based test for Property 22 of the multi-server-library-sharing
# feature.
#
# Design property (multi-server-library-sharing, Property 22):
#   For any connecting Media_Client and any library/authorization
#   configuration, the content served over the DAAP_Service or RSP_Service
#   SHALL be a subset of the Local_Library content the authenticated account is
#   authorized to access and SHALL contain no Remote_Library content; when an
#   account's authorization to a Local_Library is revoked, that Library's
#   content SHALL no longer be served to that account.
#
# The content a Media_Client is served is selected by `AuthorizedContent.for`,
# which resolves the account's browsing-authorized library set (the SAME
# `User#authorized_library_ids` derivation used for browsing/streaming) and
# filters it to LOCAL libraries so Remote_Library content is excluded
# (Req 15.8, 15.10). Because the set is recomputed from the user's current
# libraries on every call, revoking access removes that library's content
# immediately (Req 15.9).
#
# This test generates several users, several local libraries with random
# ownership and content, and several remote libraries (reached through
# per-user Library_Connections) with content. For a randomly chosen connecting
# user — including a user authorized to zero libraries — it computes the
# expected served set INDEPENDENTLY (the content of exactly the local libraries
# that user owns) and asserts that `AuthorizedContent.for(user)`:
#   * (exactly)      serves songs/albums/artists equal to that expected set,
#   * (containment)  serves nothing from libraries the user cannot access, and
#   * (no remote)    serves no Remote_Library content whatsoever (Req 15.10).
class AuthorizationContainmentPropertyTest < ActiveSupport::TestCase
  # A readable directory so freshly created local libraries pass media-path
  # validation (Req 1.3/1.4); the fixtures directory always exists.
  MEDIA_PATH = Rails.root.join("test", "fixtures", "files").to_s

  setup do
    @seq = 0
  end

  # Feature: multi-server-library-sharing, Property 22: DAAP/RSP served content is local and authorized
  test "a Media_Client is served exactly its account's authorized local content, never unauthorized or remote content" do
    check_property(iterations: 100) do
      # Shape of one iteration's dataset. Runs in a Rantly instance, so
      # range/choose are called on `self`.
      user_count = range(1, 4)

      # Each local library: which user owns it (-1 = unowned, authorized to no
      # one) and how many content triples (artist/album/song) it holds.
      local_specs = Array.new(range(1, 4)) do
        { owner_index: range(-1, user_count - 1), content_count: range(0, 3) }
      end

      # Each remote library: which user reaches it through a Library_Connection,
      # that connection's status, and how much content it holds. Only `active`
      # connections put the remote library in the user's browsing-authorized
      # set — and even then Property 22 requires it stay OUT of the served set.
      remote_specs = Array.new(range(0, 3)) do
        {
          conn_user_index: range(0, user_count - 1),
          status: choose(:active, :revoked, :unavailable),
          content_count: range(0, 3)
        }
      end

      # Which user's Media_Client connects. -1 models a freshly created account
      # authorized to zero libraries (the empty-set case).
      connecting_index = range(-1, user_count - 1)

      [ user_count, local_specs, remote_specs, connecting_index ]
    end.check do |(user_count, local_specs, remote_specs, connecting_index)|
      reset_state

      users = Array.new(user_count) { create_user }

      # library_id => { song_ids:, album_ids:, artist_ids: } for every library.
      content = {}
      # Local libraries indexed by their owning user id (nil for unowned).
      local_owner_of = {}
      remote_library_ids = []

      local_specs.each do |spec|
        owner = spec[:owner_index].negative? ? nil : users[spec[:owner_index]]
        library = create_local_library(owner:)
        local_owner_of[library.id] = owner&.id
        content[library.id] = build_content(library, spec[:content_count])
      end

      remote_specs.each do |spec|
        conn = create_connection(user: users[spec[:conn_user_index]], status: spec[:status].to_s)
        library = create_remote_library(connection: conn)
        remote_library_ids << library.id
        content[library.id] = build_content(library, spec[:content_count])
      end

      connecting_user = connecting_index.negative? ? create_user : users[connecting_index]

      # --- Independently compute the EXPECTED served set. -------------------
      # The account is served exactly the content of the LOCAL libraries it
      # owns; unowned locals, other users' locals, and all remotes are excluded.
      authorized_local_ids = local_owner_of.select { |_lib_id, owner_id| owner_id == connecting_user.id }.keys

      expected = {
        song_ids: authorized_local_ids.flat_map { |lib_id| content[lib_id][:song_ids] }.to_set,
        album_ids: authorized_local_ids.flat_map { |lib_id| content[lib_id][:album_ids] }.to_set,
        artist_ids: authorized_local_ids.flat_map { |lib_id| content[lib_id][:artist_ids] }.to_set
      }

      # Everything the account must NOT be served: every other library's content.
      unauthorized_library_ids = content.keys - authorized_local_ids
      unauthorized = {
        song_ids: unauthorized_library_ids.flat_map { |lib_id| content[lib_id][:song_ids] }.to_set,
        album_ids: unauthorized_library_ids.flat_map { |lib_id| content[lib_id][:album_ids] }.to_set,
        artist_ids: unauthorized_library_ids.flat_map { |lib_id| content[lib_id][:artist_ids] }.to_set
      }

      # Remote-only content, called out explicitly for Req 15.10.
      remote = {
        song_ids: remote_library_ids.flat_map { |lib_id| content[lib_id][:song_ids] }.to_set,
        album_ids: remote_library_ids.flat_map { |lib_id| content[lib_id][:album_ids] }.to_set,
        artist_ids: remote_library_ids.flat_map { |lib_id| content[lib_id][:artist_ids] }.to_set
      }

      served = AuthorizedContent.for(connecting_user)
      served_song_ids = served.songs.ids.to_set
      served_album_ids = served.albums.ids.to_set
      served_artist_ids = served.artists.ids.to_set

      # (exactly) The served set equals the authorized local content — no more,
      # no less. When the account owns no local libraries this asserts an empty
      # served set (Req 15.8).
      assert_equal expected[:song_ids], served_song_ids,
        "served songs must equal exactly the account's authorized local songs"
      assert_equal expected[:album_ids], served_album_ids,
        "served albums must equal exactly the account's authorized local albums"
      assert_equal expected[:artist_ids], served_artist_ids,
        "served artists must equal exactly the account's authorized local artists"

      # (containment) Nothing from an unauthorized library is ever served
      # (Req 15.8, 15.9).
      assert (served_song_ids & unauthorized[:song_ids]).empty?,
        "served songs must contain no unauthorized-library content"
      assert (served_album_ids & unauthorized[:album_ids]).empty?,
        "served albums must contain no unauthorized-library content"
      assert (served_artist_ids & unauthorized[:artist_ids]).empty?,
        "served artists must contain no unauthorized-library content"

      # (no remote) No Remote_Library content is ever served, even when the
      # account reaches that remote through an active connection (Req 15.10).
      assert (served_song_ids & remote[:song_ids]).empty?,
        "served songs must contain no Remote_Library content"
      assert (served_album_ids & remote[:album_ids]).empty?,
        "served albums must contain no Remote_Library content"
      assert (served_artist_ids & remote[:artist_ids]).empty?,
        "served artists must contain no Remote_Library content"
    end
  end

  private

  def next_seq
    @seq += 1
  end

  # Remove content, connections, generated users, and non-fixture libraries so
  # each iteration observes only the dataset it builds.
  def reset_state
    Song.delete_all
    Album.delete_all
    Artist.delete_all
    LibraryConnection.delete_all
    fixture_ids = [ libraries(:default_library).id, libraries(:secondary_library).id ]
    Library.where.not(id: fixture_ids).delete_all
    User.where("email LIKE ?", "prop22-%").destroy_all
  end

  def create_user
    User.create!(email: "prop22-#{SecureRandom.uuid}@example.com", password: "foobar123")
  end

  # A local library optionally owned by `owner`. Only libraries the connecting
  # user owns are authorized for that user (accessible_libraries is owned-local).
  def create_local_library(owner:)
    Library.create!(name: "Prop22-Local-#{next_seq}", kind: "local", media_path: MEDIA_PATH, owner:)
  end

  # A remote library reached through `connection`. Remote libraries skip
  # media-path validation and are never `Library.local`, so their content must
  # never be served by AuthorizedContent (Req 15.10).
  def create_remote_library(connection:)
    Library.create!(name: "Prop22-Remote-#{next_seq}", kind: "remote", library_connection: connection)
  end

  def create_connection(user:, status:)
    connection = LibraryConnection.new(user:, status:)
    connection.grant_token = "grant-#{next_seq}"
    connection.save!
    connection
  end

  # Create `count` distinct artist/album/song triples scoped to `library`.
  # Returns { song_ids:, album_ids:, artist_ids: }.
  def build_content(library, count)
    song_ids = []
    album_ids = []
    artist_ids = []

    count.times do
      n = next_seq
      artist = Artist.create!(name: "Artist-#{n}", library:)
      album = Album.create!(name: "Album-#{n}", artist:, library:)
      song = Song.create!(
        name: "Song-#{n}",
        file_path: "/tmp/song-#{n}.mp3",
        file_path_hash: "fph-#{n}",
        md5_hash: "md5-#{n}",
        library:,
        album:,
        artist:
      )

      song_ids << song.id
      album_ids << album.id
      artist_ids << artist.id
    end

    { song_ids:, album_ids:, artist_ids: }
  end
end
