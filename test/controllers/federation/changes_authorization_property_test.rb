# frozen_string_literal: true

require "test_helper"

module Federation
  # Property-based test for Property 3 of the remote-library-mirror-sync feature.
  #
  # Design property (remote-library-mirror-sync, Property 3):
  #   For any presented credential token and any set of Access_Grants in
  #   arbitrary states, the Changes_Since_API SHALL return Catalog_Changes if
  #   and only if the token matches exactly one Access_Grant whose status is
  #   active, whose expiration is in the future, and which references the
  #   requested Library; in every other case it SHALL reject with an
  #   authorization error and return no changes (Req 3.3, 9.4).
  #
  # This is an integration-style property test that drives the real HTTP path:
  # `GET /federation/libraries/:library_id/changes` with a Bearer token, exactly
  # as a redeeming Server would call it. Authorization is enforced by
  # `Federation::ChangesController` reusing `authorize_federation!` from
  # `Federation::BaseController` (grant digest match + `usable?` + library
  # reference). It mirrors the existing multi-server-library-sharing Property 10
  # test but targets the changes endpoint over the wire rather than the concern
  # in isolation.
  #
  # Because `token_digest` carries a unique index, a token resolves to at most
  # one grant, so "exactly one matching grant" is structurally guaranteed. Each
  # created local library is seeded with a real Catalog_Change so an authorized
  # request observably returns a non-empty change set (200), while every
  # unauthorized case is rejected with a 403 and no change payload.
  class ChangesAuthorizationPropertyTest < ActionDispatch::IntegrationTest
    # A readable directory so freshly created local libraries pass media-path
    # validation; the fixtures directory always exists.
    MEDIA_PATH = Rails.root.join("test", "fixtures", "files").to_s
    AUDIO_FIXTURE = Rails.root.join("test", "fixtures", "files", "artist1_album2.mp3").to_s

    setup do
      @seq = 0

      # Snapshot the fixture rows so each iteration can delete only the content
      # it generated and observe just the dataset it builds.
      @fixture_song_ids = Song.ids
      @fixture_album_ids = Album.ids
      @fixture_artist_ids = Artist.ids
      @fixture_library_ids = Library.ids
    end

    # Feature: remote-library-mirror-sync, Property 3: Changes-since requires an authorized, active, non-revoked, non-expired grant referencing the library
    test "the changes endpoint returns Catalog_Changes iff the Bearer token matches exactly one active, unexpired grant for the requested local library, else rejects with 403 and no changes" do
      check_property(iterations: 120) do
        # Shape of the dataset for one iteration. Runs in a Rantly instance, so
        # range/choose are on `self`.
        lib_count = range(1, 3)

        # Each grant: [library index, status, expiration bucket].
        grant_specs = Array.new(range(0, 4)) do
          [ range(0, lib_count - 1), choose(:active, :revoked), choose(:none, :past, :future) ]
        end

        # Which token to present: an index into grant_specs, or -1 for a token
        # that matches no stored grant.
        token_selector = grant_specs.empty? ? -1 : range(-1, grant_specs.size - 1)

        # Which library to name in the request:
        #   :local  -> one of the created local libraries (index below),
        #   :remote -> a remote library (never authorizable: not local),
        #   :bogus  -> a non-existent library id.
        requested_kind = choose(:local, :remote, :bogus)
        requested_local_index = range(0, lib_count - 1)

        [ lib_count, grant_specs, token_selector, requested_kind, requested_local_index ]
      end.check do |(lib_count, grant_specs, token_selector, requested_kind, requested_local_index)|
        reset_state

        # Each local library is seeded with a real Catalog_Change so an
        # authorized request returns a non-empty change set.
        libraries = Array.new(lib_count) { create_seeded_local_library }

        # Materialize grants with distinct, known plaintext tokens (globally
        # unique via the digest column's unique index) so we can present any one
        # verbatim.
        grants = grant_specs.map do |(lib_index, status, expiry)|
          create_grant(
            library: libraries[lib_index],
            token: "tok-#{next_seq}",
            status: status.to_s,
            expires_at: expiration_for(expiry)
          )
        end

        presented_token =
          if token_selector.negative?
            "absent-#{next_seq}" # matches no stored grant
          else
            grants[token_selector].token
          end

        requested_library_id =
          case requested_kind
          when :local then libraries[requested_local_index].id
          when :remote then create_remote_library.id
          else bogus_library_id
          end

        # Independently compute the expected authorization outcome. A token
        # resolves to at most one grant (unique digest); it must be active,
        # unexpired, and reference the requested library, which must exist and
        # be local (Req 3.3, 9.4).
        matched = grants.find { |g| g.token == presented_token }
        requested_library = Library.local.find_by(id: requested_library_id)
        authorized =
          !matched.nil? &&
          matched.active? &&
          !matched.expired? &&
          !requested_library.nil? &&
          matched.library_id == requested_library.id

        get federation_library_changes_url(library_id: requested_library_id),
          headers: { authorization: "Bearer #{presented_token}" },
          as: :json

        if authorized
          assert_response :success,
            "expected the changes endpoint to serve an authorized, active, unexpired grant for its own local library"
          body = @response.parsed_body
          assert body.is_a?(Hash) && body.key?("changes"),
            "expected an authorized response to return a Catalog_Changes payload"
          refute_empty body["changes"],
            "expected the seeded Catalog_Change to be returned to an authorized request"
        else
          assert_response :forbidden,
            "expected 403 (authorization error) for an unauthorized changes request"
          refute_includes @response.body.to_s, "\"changes\"",
            "expected no Catalog_Changes to be returned on an authorization rejection"
        end
      end
    end

    private

    def next_seq
      @seq += 1
    end

    # Remove grants, the change log, and every non-fixture row this test built
    # so each iteration observes only its own dataset. Songs are deleted before
    # albums/artists to respect the foreign keys, and libraries last.
    def reset_state
      AccessGrant.delete_all
      CatalogChange.delete_all
      Song.where.not(id: @fixture_song_ids).delete_all
      Album.where.not(id: @fixture_album_ids).delete_all
      Artist.where.not(id: @fixture_artist_ids).delete_all
      Library.where.not(id: @fixture_library_ids).delete_all
    end

    # A local library carrying one real upsert Catalog_Change at version 1, so a
    # cursor of 0 (the default) yields a non-empty change set.
    def create_seeded_local_library
      library = Library.create!(name: "Prop3-Local-#{next_seq}", kind: "local", media_path: MEDIA_PATH)

      artist = Artist.create!(name: "Prop3-Artist-#{next_seq}", library: library)
      album = Album.create!(name: "Prop3-Album-#{next_seq}", artist: artist, library: library)
      song = Song.create!(
        name: "Prop3-Song-#{next_seq}",
        file_path: AUDIO_FIXTURE,
        file_path_hash: "prop3-fph-#{next_seq}",
        md5_hash: "prop3-md5-#{next_seq}",
        album: album,
        artist: artist,
        library: library,
        duration: 8.0
      )

      CatalogChange.create!(
        library: library,
        version: 1,
        item_type: "song",
        item_id: song.id,
        change_type: "upsert"
      )
      library.update!(catalog_version: 1)

      library
    end

    # Remote libraries are never `Library.local`, so naming one in a request
    # must never authorize content.
    def create_remote_library
      Library.create!(name: "Prop3-Remote-#{next_seq}", kind: "remote")
    end

    # An id guaranteed not to reference any existing library.
    def bogus_library_id
      (Library.maximum(:id) || 0) + 10_000
    end

    def expiration_for(bucket)
      case bucket
      when :past then 1.day.ago
      when :future then 1.day.from_now
      else nil # never expires
      end
    end

    # Persist a grant for `library` with a known plaintext token so the test can
    # present that exact token as a Bearer credential.
    def create_grant(library:, token:, status:, expires_at:)
      grant = AccessGrant.new(library: library, status: status, expires_at: expires_at)
      grant.token = token
      grant.save!
      grant
    end
  end
end
