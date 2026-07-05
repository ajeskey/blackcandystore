# frozen_string_literal: true

require "test_helper"

# Shared unit tests for the Rails-side Media_Client service boundary (Req 15).
# The behavior is identical for DAAP and RSP; each concrete test class supplies
# its `service_class` and `enable_flag`, so both DAAPService and RSPService are
# exercised against the same enablement / authentication / authorized-content
# contract. The DAAP/RSP wire protocol itself is external and integration/smoke
# tested in task 29.2 — not here.
module MediaClientServiceBehavior
  extend ActiveSupport::Concern

  included do
    setup do
      # visitor1 owns the Default_Library, which holds every fixture Song,
      # Album, and Artist — the account authorized to that local content.
      @owner = users(:visitor1)
      @default_library = libraries(:default_library)
      @media_path = Rails.root.join("test", "fixtures", "files").to_s
      disable!
    end

    # --- Enablement gating (Req 15.3, 15.4, 15.5) ------------------------------

    test "enabled? reflects the Setting flag" do
    assert_not service_class.enabled?

    enable!
    assert service_class.enabled?

    disable!
    assert_not service_class.enabled?
  end

  test "connect is refused while the service is disabled and serves no content" do
    error = assert_raises(MediaClientService::Disabled) do
      service_class.connect(email: @owner.email, password: "foobar")
    end
    assert_match(/disabled/, error.message)
  end

  test "a disabled service instance serves no content even when bound to an authorized account" do
    service = service_class.new(@owner)

    assert_not service.enabled?
    assert_empty service.songs
    assert_empty service.albums
    assert_empty service.artists
  end

  # --- Authentication (Req 15.6, 15.7) -----------------------------------------

  test "connect refuses an unknown account with an authentication error" do
    enable!

    assert_raises(MediaClientService::AuthenticationError) do
      service_class.connect(email: "nobody@blackcandy.com", password: "foobar")
    end
  end

  test "connect refuses a wrong password with an authentication error" do
    enable!

    assert_raises(MediaClientService::AuthenticationError) do
      service_class.connect(email: @owner.email, password: "wrong-password")
    end
  end

  test "authenticate returns the account on valid credentials and nil otherwise" do
    assert_equal @owner, service_class.authenticate(email: @owner.email, password: "foobar")
    assert_nil service_class.authenticate(email: @owner.email, password: "wrong-password")
    assert_nil service_class.authenticate(email: "nobody@blackcandy.com", password: "foobar")
  end

  test "connect returns a service bound to the authenticated account when enabled" do
    enable!

    service = service_class.connect(email: @owner.email, password: "foobar")

    assert_instance_of service_class, service
    assert_equal @owner, service.user
  end

  # --- Authorized content only (Req 15.8, 15.10; Property 22) ------------------

  test "a connected service serves exactly the authorized local content" do
    enable!
    service = service_class.connect(email: @owner.email, password: "foobar")

    expected_songs = Song.where(library_id: @default_library.id).order(:id).to_a
    expected_albums = Album.where(library_id: @default_library.id).order(:id).to_a
    expected_artists = Artist.where(library_id: @default_library.id).order(:id).to_a

    # Sanity check the account genuinely has content so equality is not vacuous.
    assert_not_empty expected_songs
    assert_not_empty expected_albums
    assert_not_empty expected_artists

    assert_equal expected_songs, service.songs.order(:id).to_a
    assert_equal expected_albums, service.albums.order(:id).to_a
    assert_equal expected_artists, service.artists.order(:id).to_a
  end

  test "does not serve another account's library content" do
    enable!
    other = users(:visitor2)
    _lib, other_song, other_album, other_artist = build_owned_content(other, "Other")

    service = service_class.connect(email: @owner.email, password: "foobar")

    assert_not_includes service.songs, other_song
    assert_not_includes service.albums, other_album
    assert_not_includes service.artists, other_artist
  end

  test "never serves Remote_Library content" do
    enable!
    _remote_lib, remote_song, remote_album, remote_artist = build_remote_content("Remote")

    service = service_class.connect(email: @owner.email, password: "foobar")

    assert_not_includes service.songs, remote_song
    assert_not_includes service.albums, remote_album
    assert_not_includes service.artists, remote_artist
    # Everything served belongs to a local library.
    assert_empty service.songs.joins(:library).where.not(libraries: { kind: "local" })
  end

  test "revoking an account's authorization stops serving that library's content" do
    enable!
    service = service_class.connect(email: @owner.email, password: "foobar")
    assert_not_empty service.songs

    # Reassign the library to another owner: the served set is recomputed from
    # the account's current libraries and no longer includes that content.
    @default_library.update!(owner: users(:visitor2))

    assert_empty service.songs
    assert_empty service.albums
    assert_empty service.artists
  end

  test "an account authorized to zero libraries is served nothing" do
    enable!
    service = service_class.connect(email: users(:admin).email, password: "foobar")

    assert_empty service.songs
    assert_empty service.albums
    assert_empty service.artists
  end

  test "a nil (unbound) user is served nothing" do
    enable!
    service = service_class.new(nil)

    assert_empty service.songs
    assert_empty service.albums
    assert_empty service.artists
  end
  end

  def enable!
    Setting.update(enable_flag => true)
  end

  def disable!
    Setting.update(enable_flag => false)
  end

  private

  def build_owned_content(owner, label)
    library = Library.create!(name: "#{label} Library", kind: "local", media_path: @media_path, owner: owner)
    build_content_in(library, label)
  end

  def build_remote_content(label)
    library = Library.create!(name: "#{label} Library", kind: "remote")
    build_content_in(library, label)
  end

  def build_content_in(library, label)
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

class DAAPServiceTest < ActiveSupport::TestCase
  include MediaClientServiceBehavior

  def service_class = DAAPService
  def enable_flag = :enable_daap

  test "uses the enable_daap setting flag" do
    assert_equal :enable_daap, DAAPService.enable_setting
  end

  test "protocol name is DAAP" do
    assert_equal "DAAP", DAAPService.protocol
  end
end

class RSPServiceTest < ActiveSupport::TestCase
  include MediaClientServiceBehavior

  def service_class = RSPService
  def enable_flag = :enable_rsp

  test "uses the enable_rsp setting flag" do
    assert_equal :enable_rsp, RSPService.enable_setting
  end

  test "protocol name is RSP" do
    assert_equal "RSP", RSPService.protocol
  end
end
