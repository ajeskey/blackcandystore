# frozen_string_literal: true

require "test_helper"

# Integration / smoke test for the live artwork proxy network path
# (remote-library-mirror-sync, task 16.2).
#
# A Mirrored_Album/Mirrored_Artist that lives in a `kind: remote` Library stores
# metadata and the hosting-side id ONLY — never any artwork bytes (Req 1.4).
# Artwork is proxied live at request time, exactly like audio is by
# RemoteStreamController:
#
#   Web_Player / App_Player --GET /asset/remote/:type/:id--> redeeming Server
#     redeeming Server --GET /federation/.../asset (Bearer grant)--> hosting Server
#       hosting Server --image bytes--> redeeming Server --image bytes--> player
#
# Every hosting-Server endpoint is stubbed with WebMock (the suite disallows
# real net connections), so we verify the redeeming Server's RemoteAssetController
# proxy behavior against the Cross-Server HTTP API Contract without a live peer:
#
#   * proxies artwork keyed on the STORED hosting-side id
#     (`remote_album_id` / `remote_artist_id`), never the local id   (Req 7.4)
#   * forwards the requested variant to the hosting asset endpoint    (Req 7.4)
#   * delivers the hosting Server's image bytes back with the right
#     content type                                                    (Req 7.4)
#   * surfaces the Remote_Library as unavailable (503) when the host
#     is down or rejects the grant, storing NO artwork bytes          (Req 1.4, 7.4)
#
# These are NOT property-based tests — they are example/smoke tests of the
# cross-server request/response and failure translation behavior for the live
# artwork path.
class RemoteAssetProxyTest < ActionDispatch::IntegrationTest
  # A distinct hosting Server host so the mirrored records resolve down the
  # remote path.
  HOST_BASE_URL = "https://remote-host.example.com"
  REMOTE_LIBRARY_ID = 314
  # Distinct from the local record ids so the proxy is proven to key the hosting
  # endpoint on the stored hosting-side id rather than the local id.
  REMOTE_ALBUM_ID = 8001
  REMOTE_ARTIST_ID = 8002
  GRANT_TOKEN = "super-secret-grant-token-abc123"

  setup do
    @user = users(:visitor1)
    @connection = LibraryConnection.create!(
      user: @user,
      server_base_url: HOST_BASE_URL,
      remote_library_id: REMOTE_LIBRARY_ID,
      grant_token: GRANT_TOKEN,
      status: :active
    )
    @library = Library.create!(
      name: "Remote Library #{SecureRandom.hex(4)}",
      kind: :remote,
      owner: @user,
      library_connection: @connection
    )
    # A Mirrored_Artist and Mirrored_Album carrying hosting-side ids distinct
    # from their local autoincrement ids.
    @artist = Artist.create!(name: "Mirrored Artist", library: @library)
    @artist.update_columns(remote_artist_id: REMOTE_ARTIST_ID)
    @album = Album.create!(name: "Mirrored Album", artist: @artist, library: @library)
    @album.update_columns(remote_album_id: REMOTE_ALBUM_ID)
  end

  # The hosting Server's federation asset endpoints the proxy reaches through
  # the Library_Connection, keyed on the STORED hosting-side ids.
  def hosting_album_asset_endpoint
    "#{HOST_BASE_URL}/federation/libraries/#{REMOTE_LIBRARY_ID}/albums/#{REMOTE_ALBUM_ID}/asset"
  end

  def hosting_artist_asset_endpoint
    "#{HOST_BASE_URL}/federation/libraries/#{REMOTE_LIBRARY_ID}/artists/#{REMOTE_ARTIST_ID}/asset"
  end

  # A non-trivial PNG-like binary body so we can prove byte-exact forwarding.
  def image_bytes
    ("\x89PNG\r\n\x1a\n".b + SecureRandom.bytes(2048)).b
  end

  # --- proxies album artwork keyed on the stored hosting-side id (Req 7.4) ----

  test "proxies album artwork to the hosting asset endpoint keyed on remote_album_id and forwards the variant" do
    bytes = image_bytes

    hosting = stub_request(:get, hosting_album_asset_endpoint)
      .with(
        query: { variant: "medium" },
        headers: { "Authorization" => "Bearer #{GRANT_TOKEN}" }
      )
      .to_return(status: 200, body: bytes, headers: { "Content-Type" => "image/png" })

    get remote_asset_url(type: "albums", id: @album.id, variant: "medium"),
      headers: api_token_header(@user)

    # The redeeming Server reached the hosting Server on the stored album id
    # (not the local id) with the grant and the forwarded variant.
    assert_requested(hosting)
    assert_response :success
    assert_equal bytes, response.body.b
    assert_equal bytes.bytesize, response.body.b.bytesize
    assert_equal "image/png", response.get_header("Content-Type")
    # Displayed inline as artwork, not as a download.
    assert_includes response.get_header("Content-Disposition").to_s, "inline"
  end

  # --- proxies artist artwork keyed on the stored hosting-side id (Req 7.4) ---

  test "proxies artist artwork to the hosting asset endpoint keyed on remote_artist_id and forwards the variant" do
    bytes = image_bytes

    hosting = stub_request(:get, hosting_artist_asset_endpoint)
      .with(
        query: { variant: "small" },
        headers: { "Authorization" => "Bearer #{GRANT_TOKEN}" }
      )
      .to_return(status: 200, body: bytes, headers: { "Content-Type" => "image/jpeg" })

    get remote_asset_url(type: "artists", id: @artist.id, variant: "small"),
      headers: api_token_header(@user)

    assert_requested(hosting)
    assert_response :success
    assert_equal bytes, response.body.b
    assert_equal "image/jpeg", response.get_header("Content-Type")
  end

  # --- credential stays server-side (Req 7.4) --------------------------------

  test "presents the stored credential to the hosting server but never exposes it to the player" do
    hosting = stub_request(:get, hosting_album_asset_endpoint)
      .with(headers: { "Authorization" => "Bearer #{GRANT_TOKEN}" })
      .to_return(status: 200, body: "img".b, headers: { "Content-Type" => "image/png" })

    get remote_asset_url(type: "albums", id: @album.id), headers: api_token_header(@user)

    assert_requested(hosting)
    assert_response :success
    assert_not_includes response.headers.to_s, GRANT_TOKEN
    assert_not_includes response.body, GRANT_TOKEN
    assert_nil response.get_header("Authorization")
  end

  # --- unavailability + stores no bytes when the host is down (Req 1.4, 7.4) --

  test "surfaces unavailability and stores no artwork bytes when the hosting server is down" do
    stub_request(:get, hosting_album_asset_endpoint).to_timeout

    assert_no_difference -> { ActiveStorage::Attachment.count } do
      get remote_asset_url(type: "albums", id: @album.id), headers: api_token_header(@user)
    end

    assert_response :service_unavailable
    assert_equal "RemoteLibraryUnavailable", response.parsed_body["type"]
    # No artwork bytes were stored on the mirrored album — there is nothing to
    # fall back to (Req 1.4).
    assert_not @album.reload.cover_image.attached?
  end

  test "surfaces unavailability and stores no artwork bytes when the hosting server rejects the grant" do
    stub_request(:get, hosting_artist_asset_endpoint).to_return(status: 403, body: "access revoked")

    assert_no_difference -> { ActiveStorage::Attachment.count } do
      get remote_asset_url(type: "artists", id: @artist.id), headers: api_token_header(@user)
    end

    assert_response :service_unavailable
    assert_equal "RemoteLibraryUnavailable", response.parsed_body["type"]
    assert_not @artist.reload.cover_image.attached?
  end
end
