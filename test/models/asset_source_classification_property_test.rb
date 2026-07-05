# frozen_string_literal: true

require "test_helper"

# Property-based test for Property 14 of the multi-server-library-sharing
# feature.
#
# Design property (multi-server-library-sharing, Property 14):
#   For any Album or Artist returned to the Web_Player, the App_Player, or the
#   API, the response SHALL include an Asset_Source of `local` when the record
#   belongs to a Local_Library (including the Default_Library) or `remote` when
#   it belongs to a Remote_Library; when the source resolves and a cover image
#   is present the Resolved_Asset_Path SHALL be non-empty and point to the
#   current Server for `local` sources (the ActiveStorage proxy path) and to the
#   hosting Server's derived asset endpoint for `remote` sources; and when no
#   cover image is present the Resolved_Asset_Path SHALL be empty and the cover
#   image SHALL be indicated absent.
#
# This exercises PathResolver#resolve_asset across generated Albums AND Artists
# in three library situations, each with and without a cover image:
#   * :local   - a record in a non-default Local_Library on this server
#   * :default - a record in the Default_Library (also local, Req 9.1)
#   * :remote  - a record in a Remote_Library reached through an *active*
#                Library_Connection (Req 9.1, 9.4)
#
# For each generated record it asserts:
#   (classification, Req 9.1) asset_source is "local" for local/default sources
#     and "remote" for the remote source;
#   (resolution with cover, Req 9.2, 9.3, 9.4, 9.5, 9.9) when a cover exists and
#     the source resolves, resolved_asset_path is non-empty and points at the
#     correct server -- the current-server rails_storage_proxy_path for local
#     sources and the same-origin /asset/remote/:record_type/:id proxy path for
#     remote sources (with ?variant= when a variant is requested);
#   (absent cover, Req 9.7) when no cover exists, resolved_asset_path is "" and
#     the cover image is indicated absent (present == false).
class AssetSourceClassificationPropertyTest < ActiveSupport::TestCase
  include Rails.application.routes.url_helpers

  LIBRARY_CATEGORIES = %i[local default remote].freeze
  RECORD_TYPES = %i[album artist].freeze
  # nil means "no variant requested"; :enormous is an unrecognized variant that
  # the resolver coerces to the default (:medium).
  VARIANTS = [ nil, :small, :medium, :large, :enormous ].freeze

  ASSET_VARIANTS = %i[small medium large].freeze
  DEFAULT_ASSET_VARIANT = :medium

  setup do
    @seq = 0
    @resolver = PathResolver.new
    @user = users(:visitor1)

    # The Default_Library is the pre-existing local collection (Req 9.1, 9.5).
    @default_library = libraries(:default_library)

    # A non-default Local_Library on the current server (Req 9.1). Its
    # media_path must exist and be readable to satisfy Library validation.
    @local_library = Library.create!(
      name: "Prop14-Local-#{SecureRandom.hex(4)}",
      kind: :local,
      owner: @user,
      media_path: Rails.root.join("test", "fixtures", "files").to_s
    )

    # A Remote_Library reached through an *active* Library_Connection so remote
    # asset resolution succeeds (Req 9.4).
    connection = LibraryConnection.create!(
      user: @user,
      server_base_url: "https://remote.example.com",
      remote_library_id: 4242,
      grant_token: "remote-bearer-token",
      status: :active
    )
    @remote_library = Library.create!(
      name: "Prop14-Remote-#{SecureRandom.hex(4)}",
      kind: :remote,
      owner: @user,
      library_connection: connection
    )
  end

  # Feature: multi-server-library-sharing, Property 14: Asset-source classification and resolution are consistent
  test "asset-source classification and resolution are consistent across local, default, and remote libraries for albums and artists" do
    check_property(iterations: 100) do
      category = LIBRARY_CATEGORIES[range(0, LIBRARY_CATEGORIES.length - 1)]
      record_type = RECORD_TYPES[range(0, RECORD_TYPES.length - 1)]
      with_cover = boolean
      variant = VARIANTS[range(0, VARIANTS.length - 1)]
      [ category, record_type, with_cover, variant ]
    end.check do |(category, record_type, with_cover, variant)|
      record = build_record(record_type, category)
      attach_cover_image(record) if with_cover

      result = @resolver.resolve_asset(record, user: @user, variant: variant)

      expected_source = category == :remote ? "remote" : "local"

      # (Req 9.1) Asset_Source classification follows the owning library kind.
      assert_equal expected_source, result[:asset_source],
        "expected #{expected_source} asset_source for a #{record_type} in a #{category} library"

      if with_cover
        # (Req 9.2, 9.9) A resolvable source with an available cover image yields
        # a non-empty Resolved_Asset_Path.
        assert result[:present], "expected present == true when a cover image is attached"
        assert result[:available], "expected an active/local source with a cover to resolve"
        assert_not_empty result[:resolved_asset_path],
          "expected a non-empty resolved_asset_path for a #{category} #{record_type} with a cover"

        if category == :remote
          # (Req 9.4) Remote path points at the hosting server's derived asset
          # endpoint via the same-origin proxy, forwarding the variant only when
          # one was requested.
          assert_equal expected_remote_path(record, variant), result[:resolved_asset_path],
            "expected the remote asset proxy path for a #{record_type}"
        else
          # (Req 9.3, 9.5) Local path is the current-server ActiveStorage proxy
          # path -- the same path the app produced before this feature.
          assert_equal expected_local_path(record, variant), result[:resolved_asset_path],
            "expected the current-server proxy path for a #{category} #{record_type}"
        end
      else
        # (Req 9.7) No cover image available => empty path and absent indicator.
        assert_equal "", result[:resolved_asset_path],
          "expected an empty resolved_asset_path when no cover image is present"
        assert_not result[:present],
          "expected present == false when no cover image is present"
      end
    end
  end

  private

  def next_seq
    @seq += 1
  end

  def library_for(category)
    case category
    when :local   then @local_library
    when :default then @default_library
    when :remote  then @remote_library
    end
  end

  # Build a persisted Album or Artist under the library implied by `category`.
  def build_record(record_type, category)
    library = library_for(category)
    n = next_seq

    case record_type
    when :album
      artist = Artist.create!(name: "Prop14-Artist-#{n}", library: library)
      Album.create!(name: "Prop14-Album-#{n}", artist: artist, library: library)
    when :artist
      Artist.create!(name: "Prop14-Artist-#{n}", library: library)
    end
  end

  def attach_cover_image(record)
    record.cover_image.attach(
      io: File.open(fixtures_file_path("cover_image.jpg")),
      filename: "cover_image.jpg",
      content_type: "image/jpeg"
    )
    record.reload
  end

  # Mirror PathResolver's variant normalization: an unknown or missing variant
  # coerces to the default (:medium).
  def normalize_variant(variant)
    return DEFAULT_ASSET_VARIANT if variant.nil?

    variant = variant.to_sym
    ASSET_VARIANTS.include?(variant) ? variant : DEFAULT_ASSET_VARIANT
  end

  # The current-server ActiveStorage proxy path for the (normalized) variant.
  def expected_local_path(record, variant)
    rails_storage_proxy_path(record.cover_image.variant(normalize_variant(variant)), only_path: true)
  end

  # The same-origin remote asset proxy path, with the normalized variant query
  # only when a variant was explicitly requested.
  def expected_remote_path(record, variant)
    path = "/asset/remote/#{record.class.name.tableize}/#{record.id}"
    variant.present? ? "#{path}?variant=#{normalize_variant(variant)}" : path
  end
end
