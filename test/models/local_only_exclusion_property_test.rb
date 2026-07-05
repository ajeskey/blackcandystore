# frozen_string_literal: true

require "test_helper"

# Property-based test for Property 13 of the remote-library-mirror-sync feature.
#
# Design property (remote-library-mirror-sync, Property 13):
#   For any library and authorization configuration, the content served over the
#   DAAP_Service or the RSP_Service SHALL be a subset of the current Server's
#   Local_Library content and SHALL contain no Mirrored_Song, Mirrored_Album, or
#   Mirrored_Artist; and the current Server's own Federation API endpoints SHALL
#   likewise expose no mirrored content (Req 11.1, 11.4).
#
# Local-only serving is preserved *by construction*: a Mirrored_Song/Album/Artist
# is an ordinary Song/Album/Artist row whose Library is `kind: remote`.
#   * DAAP_Service / RSP_Service serve `AuthorizedContent.for(user)`, which is
#     `Library.local.where(id: user.authorized_library_ids)` — the `.local`
#     filter drops every remote (mirror) library even when the user holds an
#     ACTIVE Library_Connection to it (so those libraries ARE in
#     `authorized_library_ids`). This is the meaningful case exercised here.
#   * The Server's own Federation API resolves its served library through
#     `Federation::BaseController#authorize_federation!` →
#     `Library.local.find_by(id: library_id)` and then scopes every content query
#     to `Song/Album/Artist.where(library_id: @library.id)`. A mirror library is
#     never `Library.local`, so a Federation request naming it resolves `@library`
#     to nil (a 403 / no content), and a Federation request naming a genuine
#     Local_Library only ever reaches that local library's rows.
#
# Each iteration generates a mixed configuration: a set of owned Local_Libraries
# with local content, plus a set of Remote_Libraries reached through ACTIVE
# Library_Connections, each holding Mirrored_Songs/Albums/Artists (rows carrying
# `remote_*_id`). It then asserts, for BOTH the DAAP_Service and the RSP_Service:
#   (subset)   the served songs/albums/artists are a subset of the Server's
#              Local_Library content;
#   (no-mirror) the served set contains none of the generated mirrored rows and
#              no row from any remote library;
# and for the Server's own Federation API:
#   (fed-hidden) every mirror library resolves to nil through `Library.local`, so
#              no Federation endpoint can reach it, and the Federation-servable
#              content of every genuine Local_Library is disjoint from the
#              mirrored rows.
class LocalOnlyExclusionPropertyTest < ActiveSupport::TestCase
  setup do
    # Both media-client services enabled so the served content is non-empty and
    # the subset/exclusion assertions are meaningful rather than vacuous.
    Setting.update(enable_daap: true, enable_rsp: true)
    @media_path = Rails.root.join("test", "fixtures", "files").to_s
    @seq = 0
  end

  # Feature: remote-library-mirror-sync, Property 13: DAAP, RSP, and the server's own Federation API expose no mirrored content
  test "DAAP/RSP serve only local content and neither they nor the own Federation API expose mirrored content" do
    check_property(iterations: 100) do
      # A configuration: several owned Local_Libraries (each with a count of
      # songs) and several Remote_Libraries reached through active connections
      # (each with a count of mirrored songs). At least one local library keeps
      # the served set non-empty; at least one remote library provides mirrored
      # content to exclude.
      local_song_counts = Array.new(range(1, 3)) { range(1, 3) }
      remote_song_counts = Array.new(range(1, 3)) { range(1, 3) }

      [ local_song_counts, remote_song_counts ]
    end.check do |(local_song_counts, remote_song_counts)|
      reset_dataset!

      user, local, mirrored, remote_library_ids, local_library_ids =
        build_config(local_song_counts, remote_song_counts)

      # Sanity: the config genuinely has both local content to serve and
      # mirrored content to exclude, so the assertions are not vacuous.
      assert_not_empty local[:song_ids], "expected generated local content"
      assert_not_empty mirrored[:song_ids], "expected generated mirrored content"

      # The mirror libraries ARE in the user's authorized set (active
      # connections) — the `.local` filter is what must exclude them.
      assert (remote_library_ids - user.authorized_library_ids).empty?,
        "expected active remote (mirror) libraries to be in the authorized set"

      [ DAAPService, RSPService ].each do |service_class|
        service = service_class.connect(email: user.email, password: "foobar123")
        assert_media_service_local_only(service_class.name, service, local, mirrored)
      end

      assert_own_federation_hides_mirrors(local_library_ids, remote_library_ids, mirrored)
    end
  end

  private

  # Assert one media-client service serves exactly the Local_Library content and
  # nothing mirrored (Req 11.1).
  def assert_media_service_local_only(label, service, local, mirrored)
    {
      Song => [ service.songs, local[:song_ids], mirrored[:song_ids] ],
      Album => [ service.albums, local[:album_ids], mirrored[:album_ids] ],
      Artist => [ service.artists, local[:artist_ids], mirrored[:artist_ids] ]
    }.each do |model, (relation, local_ids, mirrored_ids)|
      served_ids = relation.pluck(:id).to_set

      # (subset) everything served belongs to the Server's Local_Library content.
      assert served_ids.subset?(local_ids.to_set),
        "#{label} #{model.name} served #{served_ids.to_a} not a subset of local content #{local_ids}"

      # (no-mirror) nothing served is a mirrored row...
      assert (served_ids & mirrored_ids.to_set).empty?,
        "#{label} #{model.name} served mirrored rows #{(served_ids & mirrored_ids.to_set).to_a}"

      # ...and nothing served lives in a remote (mirror) library.
      assert_empty relation.joins(:library).where.not(libraries: { kind: "local" }),
        "#{label} #{model.name} served content from a non-local library"
    end
  end

  # Assert the Server's own Federation API cannot expose any mirrored content
  # (Req 11.4). The Federation base controller resolves its library through
  # `Library.local.find_by(id:)` and scopes content to that library.
  def assert_own_federation_hides_mirrors(local_library_ids, remote_library_ids, mirrored)
    mirrored_song_ids = mirrored[:song_ids].to_set
    mirrored_album_ids = mirrored[:album_ids].to_set
    mirrored_artist_ids = mirrored[:artist_ids].to_set

    # A Federation request naming a mirror library resolves to nil: unreachable.
    remote_library_ids.each do |library_id|
      assert_nil Library.local.find_by(id: library_id),
        "own Federation API could resolve mirror library #{library_id} through Library.local"
    end

    # A Federation request naming a genuine Local_Library only ever reaches that
    # local library's rows, which are disjoint from every mirrored row.
    local_library_ids.each do |library_id|
      library = Library.local.find_by(id: library_id)
      refute_nil library

      assert (Song.where(library_id: library.id).ids.to_set & mirrored_song_ids).empty?,
        "own Federation API songs for local library #{library_id} included mirrored rows"
      assert (Album.where(library_id: library.id).ids.to_set & mirrored_album_ids).empty?,
        "own Federation API albums for local library #{library_id} included mirrored rows"
      assert (Artist.where(library_id: library.id).ids.to_set & mirrored_artist_ids).empty?,
        "own Federation API artists for local library #{library_id} included mirrored rows"
    end

    # No mirrored row lives in ANY local library, so no Federation endpoint —
    # whichever local library it names — can ever serve mirrored content.
    assert_empty Song.where(id: mirrored_song_ids.to_a).joins(:library).where(libraries: { kind: "local" }),
      "a mirrored song was attributed to a local library"
    assert_empty Album.where(id: mirrored_album_ids.to_a).joins(:library).where(libraries: { kind: "local" }),
      "a mirrored album was attributed to a local library"
    assert_empty Artist.where(id: mirrored_artist_ids.to_a).joins(:library).where(libraries: { kind: "local" }),
      "a mirrored artist was attributed to a local library"
  end

  # Isolate each iteration: strip generated content and non-fixture libraries /
  # connections so assertions observe only this iteration's dataset.
  def reset_dataset!
    Song.delete_all
    Album.delete_all
    Artist.delete_all
    fixture_library_ids = [ libraries(:default_library).id, libraries(:secondary_library).id ]
    Library.where.not(id: fixture_library_ids).delete_all
    LibraryConnection.delete_all if defined?(LibraryConnection) && LibraryConnection.table_exists?
    User.where("email LIKE ?", "prop13-%@example.com").delete_all
  end

  def next_seq
    @seq += 1
  end

  # Build the mixed configuration and return the owning user, the local content
  # id sets, the mirrored content id sets, the remote (mirror) library ids, and
  # the local library ids.
  def build_config(local_song_counts, remote_song_counts)
    user = User.create!(email: "prop13-#{SecureRandom.uuid}@example.com", password: "foobar123")

    local = { song_ids: [], album_ids: [], artist_ids: [] }
    mirrored = { song_ids: [], album_ids: [], artist_ids: [] }
    local_library_ids = []
    remote_library_ids = []

    local_song_counts.each do |count|
      library = Library.create!(
        name: "Prop13-Local-#{next_seq}", kind: "local", media_path: @media_path, owner: user
      )
      local_library_ids << library.id
      count.times { build_local_content(library, local) }
    end

    remote_song_counts.each do |count|
      n = next_seq
      connection = LibraryConnection.create!(
        user: user,
        server_base_url: "https://host#{n}.example",
        remote_library_id: n,
        grant_token: "token#{n}",
        status: :active,
        sync_state: "fresh"
      )
      library = Library.create!(
        name: "Prop13-Remote-#{n}", kind: :remote, library_connection: connection
      )
      remote_library_ids << library.id
      count.times { build_mirrored_content(library, mirrored) }
    end

    [ user, local, mirrored, remote_library_ids, local_library_ids ]
  end

  # A local Song/Album/Artist triple in a Local_Library.
  def build_local_content(library, acc)
    n = next_seq
    artist = Artist.create!(name: "Local-Artist-#{n}", library: library)
    album = Album.create!(name: "Local-Album-#{n}", artist: artist, library: library)
    song = Song.create!(
      name: "Local-Song-#{n}",
      file_path: File.join(@media_path, "artist1_album1.flac"),
      file_path_hash: "prop13-local-fph-#{n}",
      md5_hash: "prop13-local-md5-#{n}",
      artist: artist,
      album: album,
      library: library
    )
    acc[:artist_ids] << artist.id
    acc[:album_ids] << album.id
    acc[:song_ids] << song.id
  end

  # A metadata-only Mirrored_Song/Album/Artist triple in a Remote_Library, each
  # carrying a hosting-side identifier and no file bytes.
  def build_mirrored_content(library, acc)
    n = next_seq
    artist = Artist.create!(name: "Mirror-Artist-#{n}", library: library, remote_artist_id: n)
    album = Album.create!(name: "Mirror-Album-#{n}", artist: artist, library: library, remote_album_id: n)
    song = Song.create!(
      name: "Mirror-Song-#{n}",
      artist: artist,
      album: album,
      library: library,
      remote_song_id: n
    )
    acc[:artist_ids] << artist.id
    acc[:album_ids] << album.id
    acc[:song_ids] << song.id
  end
end
