# frozen_string_literal: true

require "test_helper"

# Property-based test for Property 10 of the multi-server-library-sharing
# feature.
#
# Design property (multi-server-library-sharing, Property 10):
#   For any presented credential token and any set of Access_Grants in
#   arbitrary states, the hosting Server's Library_Access_Controller SHALL
#   return the requested Library's content if and only if the token matches
#   exactly one Access_Grant whose status is active, whose `expires_at` is in
#   the future, and which references the requested (local) Library; in every
#   other case it SHALL reject with an authorization error and return no
#   content (Req 6.5, 6.6, 6.8, 7.3, 7.4).
#
# The federation authorization decision lives in `authorize_grant!` on the
# LibraryAccess concern: it hashes+constant-time-compares the presented token
# (AccessGrant.find_by_token), then applies defense-in-depth checks — the
# matched grant must be active and unexpired (`usable?`) and must reference the
# requested library, which must still exist and be local. Any failure raises
# BlackCandy::Forbidden (returning no content); success returns the matched
# grant so the caller can serve content.
#
# Because `token_digest` carries a unique index, a token resolves to at most one
# grant, so "exactly one matching grant" is structurally guaranteed. This test
# generates a set of grants spread across libraries in mixed states
# (active/revoked, no-expiry/past/future) and a presented (token, library_id)
# pair that may or may not match. It computes the expected outcome
# independently and asserts:
#   * authorized  -> authorize_grant! returns exactly that grant, and
#   * otherwise   -> authorize_grant! raises BlackCandy::Forbidden (no content).
class FederationAuthorizationPropertyTest < ActiveSupport::TestCase
  # A minimal host that mixes in the concern so its private federation helper
  # can be exercised in isolation, the same way a controller would use it.
  class Host
    include LibraryAccess

    public :authorize_grant!
  end

  # A readable directory so freshly created local libraries pass media-path
  # validation (Req 1.3/1.4); the fixtures directory always exists.
  MEDIA_PATH = Rails.root.join("test", "fixtures", "files").to_s

  setup do
    @host = Host.new
    @seq = 0
  end

  # Feature: multi-server-library-sharing, Property 10: Federation content requires an authorized, active, non-revoked grant
  test "authorize_grant! returns the grant iff the token matches exactly one active, unexpired grant for the requested local library, else raises Forbidden" do
    check_property(iterations: 150) do
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
      #   :remote -> a remote library (never authorizable: not local, Req 6.8),
      #   :bogus  -> a non-existent library id.
      requested_kind = choose(:local, :remote, :bogus)
      requested_local_index = range(0, lib_count - 1)

      [ lib_count, grant_specs, token_selector, requested_kind, requested_local_index ]
    end.check do |(lib_count, grant_specs, token_selector, requested_kind, requested_local_index)|
      reset_state

      libraries = Array.new(lib_count) { create_local_library }

      # Materialize the grants with distinct, known plaintext tokens so we can
      # present any one of them verbatim. Tokens are globally unique (the digest
      # column has a unique index).
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
          # A token that matches no stored grant (distinct "absent-" prefix).
          "absent-#{next_seq}"
        else
          grants[token_selector].token
        end

      requested_library_id =
        case requested_kind
        when :local
          libraries[requested_local_index].id
        when :remote
          create_remote_library.id
        else # :bogus
          bogus_library_id
        end

      # Independently compute the expected authorization outcome. A token
      # resolves to at most one grant (unique digest), which must be active,
      # unexpired, and reference the requested library — and that library must
      # exist and be local (Req 6.5, 6.6, 6.8, 7.3, 7.4).
      matched = grants.find { |g| g.token == presented_token }
      requested_library = Library.local.find_by(id: requested_library_id)
      authorized =
        !matched.nil? &&
        matched.active? &&
        !matched.expired? &&
        !requested_library.nil? &&
        matched.library_id == requested_library.id

      if authorized
        assert_equal matched, @host.authorize_grant!(presented_token, requested_library_id),
          "expected the matched active/unexpired grant to be returned for its own local library"
      else
        assert_raises(BlackCandy::Forbidden,
          "expected Forbidden (no content) for an unauthorized federation request") do
          @host.authorize_grant!(presented_token, requested_library_id)
        end
      end
    end
  end

  private

  def next_seq
    @seq += 1
  end

  # Remove any grants and non-fixture libraries so each iteration observes only
  # the dataset it builds.
  def reset_state
    AccessGrant.delete_all
    fixture_ids = [ libraries(:default_library).id, libraries(:secondary_library).id ]
    Library.where.not(id: fixture_ids).delete_all
  end

  def create_local_library
    Library.create!(name: "Prop10-Local-#{next_seq}", kind: "local", media_path: MEDIA_PATH)
  end

  # Remote libraries skip media-path validation and are never `Library.local`,
  # so naming one in a request must never authorize content.
  def create_remote_library
    Library.create!(name: "Prop10-Remote-#{next_seq}", kind: "remote")
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
  # present that exact token to `authorize_grant!`.
  def create_grant(library:, token:, status:, expires_at:)
    grant = AccessGrant.new(library: library, status: status, expires_at: expires_at)
    grant.token = token
    grant.save!
    grant
  end
end
