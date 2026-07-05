# frozen_string_literal: true

require "test_helper"

class AuthorizedContentTest < ActiveSupport::TestCase
  setup do
    # visitor1 owns the Default_Library, which holds every fixture Song, Album,
    # and Artist. That makes it the account authorized to that local content.
    @owner = users(:visitor1)
    @default_library = libraries(:default_library)
    @media_path = Rails.root.join("test", "fixtures", "files").to_s
  end

  test "for exposes the songs, albums, and artists of the owner's authorized local libraries" do
    content = AuthorizedContent.for(@owner)

    expected_songs = Song.where(library_id: @default_library.id).order(:id).to_a
    expected_albums = Album.where(library_id: @default_library.id).order(:id).to_a
    expected_artists = Artist.where(library_id: @default_library.id).order(:id).to_a

    # Sanity check: the owner genuinely has content so the equality below is not
    # a vacuous empty-vs-empty comparison.
    assert_not_empty expected_songs
    assert_not_empty expected_albums
    assert_not_empty expected_artists

    assert_equal expected_songs, content.songs.order(:id).to_a
    assert_equal expected_albums, content.albums.order(:id).to_a
    assert_equal expected_artists, content.artists.order(:id).to_a
  end

  test "excludes content belonging to another user's library" do
    other = users(:visitor2)
    other_library, other_song, other_album, other_artist = build_owned_content(other, "Other")

    content = AuthorizedContent.for(@owner)

    assert_not_includes content.songs, other_song
    assert_not_includes content.albums, other_album
    assert_not_includes content.artists, other_artist

    # And the other account sees exactly its own content, never the owner's.
    other_content = AuthorizedContent.for(other)
    assert_includes other_content.songs, other_song
    assert_includes other_content.albums, other_album
    assert_includes other_content.artists, other_artist
    assert_not_includes other_content.songs, songs(:mp3_sample)
    assert_not_includes other_content.albums, albums(:album1)
    assert_not_includes other_content.artists, artists(:artist1)

    # The served set is scoped to that library only.
    assert_equal [ other_library.id ], other_content.songs.pluck(:library_id).uniq
  end

  test "a user authorized to zero libraries gets empty sets" do
    # admin owns no libraries, so it is authorized to no local content.
    no_access = users(:admin)
    assert_empty no_access.authorized_library_ids

    content = AuthorizedContent.for(no_access)

    assert_empty content.songs
    assert_empty content.albums
    assert_empty content.artists
  end

  test "a nil (unauthenticated) user gets empty sets" do
    content = AuthorizedContent.for(nil)

    assert_empty content.songs
    assert_empty content.albums
    assert_empty content.artists
  end

  test "revoking access to a library removes its content from the served set" do
    content_ids = -> { AuthorizedContent.for(@owner).songs.ids.sort }

    assert_not_empty content_ids.call

    # Revoke the owner's authorization by reassigning the library to someone
    # else; the served set is recomputed and no longer includes that content.
    @default_library.update!(owner: users(:visitor2))

    assert_empty content_ids.call
  end

  private

  # Create a local library owned by `owner` with a single Artist, Album, and
  # Song scoped to it. Returns [library, song, album, artist].
  def build_owned_content(owner, label)
    library = Library.create!(name: "#{label} Library", kind: "local", media_path: @media_path, owner: owner)
    artist = Artist.create!(name: "#{label} Artist", library: library)
    album = Album.create!(name: "#{label} Album", artist: artist, library: library)
    song = Song.create!(
      name: "#{label} Song",
      file_path: File.join(@media_path, "artist1_album1.flac"),
      file_path_hash: "#{label.downcase}_file_path_hash",
      md5_hash: "#{label.downcase}_md5_hash",
      artist: artist,
      album: album,
      library: library
    )

    [ library, song, album, artist ]
  end
end
