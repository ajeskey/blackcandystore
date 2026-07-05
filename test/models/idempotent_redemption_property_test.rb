# frozen_string_literal: true

require "test_helper"

# Property-based test for idempotent Invite_Code redemption.
#
# Design property (multi-server-library-sharing, Property 9):
#   Redeeming a non-revoked Invite_Code that the same User has already redeemed
#   SHALL report success and SHALL leave state unchanged — no duplicate
#   Access_Grant redemption on the local path (Req 5.6) and no duplicate
#   Library_Connection on the cross-server path (Req 5.9).
#
# Each iteration exercises one of the two redemption paths against a freshly
# built, non-revoked grant:
#
#   * Local path (Req 5.6): create an active Access_Grant for a local Library,
#     redeem it once for a User (recording redeemer + redeemed_at), then redeem
#     the identical code again for the same User. The repeat MUST succeed, MUST
#     NOT create another Access_Grant, and MUST leave redeemed_at unchanged.
#
#   * Cross-server path (Req 5.9): stub the issuing Server's grant-confirmation
#     endpoint, redeem a code that points at that Server (creating a single
#     Library_Connection), then redeem the identical code again for the same
#     User. The repeat MUST succeed, MUST reuse the existing Library_Connection
#     (same id), and MUST NOT create a duplicate — as enforced by the unique
#     index on [user_id, server_base_url, remote_library_id].
#
# Tokens, redeeming Users, remote hosts and remote Library ids are all varied by
# the generator so idempotency is asserted across a broad range of inputs.
class IdempotentRedemptionPropertyTest < ActiveSupport::TestCase
  USER_KEYS = %i[admin visitor1 visitor2].freeze

  # Feature: multi-server-library-sharing, Property 9: Redemption is idempotent
  test "re-redeeming a non-revoked code the same user already redeemed succeeds with no state change" do
    check_property(iterations: 120) do
      # self is a Rantly instance here. Return only primitives describing the
      # scenario; all DB work happens in the assertion block below.
      #
      # A UUID guarantees each generated token is globally unique so the
      # AccessGrant token_digest unique index never collides across iterations,
      # while the appended alnum segment keeps the token content varied.
      token = "#{SecureRandom.uuid}-#{sized(range(1, 24)) { string(:alnum) }}"
      user_key = choose(*USER_KEYS)

      case choose(:local, :remote)
      when :local
        [ :local, token, user_key, nil, nil ]
      when :remote
        remote_host = "https://host-#{SecureRandom.hex(4)}.example.com"
        remote_library_id = range(1, 1_000_000)
        [ :remote, token, user_key, remote_host, remote_library_id ]
      end
    end.check do |(path, token, user_key, remote_host, remote_library_id)|
      user = users(user_key)

      if path == :local
        grant = create_local_grant(token: token)

        first = InviteManager.redeem(invite_code: local_code(token), user: user)
        assert first.success?
        assert_equal grant, first.access_grant
        assert_nil first.connection

        redeemed_at = grant.reload.redeemed_at
        assert_not_nil redeemed_at
        grants_after_first = AccessGrant.count
        connections_after_first = LibraryConnection.count

        # Re-redeem the identical code for the same User (Req 5.6).
        second = InviteManager.redeem(invite_code: local_code(token), user: user)

        assert second.success?, "repeat local redemption should report success"
        assert_equal grant, second.access_grant, "repeat redemption should reuse the same grant"
        assert_nil second.connection
        assert_equal grants_after_first, AccessGrant.count,
          "repeat local redemption created a duplicate Access_Grant"
        assert_equal connections_after_first, LibraryConnection.count,
          "repeat local redemption created a Library_Connection"
        assert_equal redeemed_at.to_f, grant.reload.redeemed_at.to_f,
          "repeat local redemption changed redeemed_at"
      else
        stub_confirm_success(remote_host, library_id: remote_library_id)

        first = InviteManager.redeem(invite_code: remote_code(token, remote_host), user: user)
        assert first.success?
        connection = first.connection
        assert_not_nil connection, "cross-server redemption should create a Library_Connection"
        assert_nil first.access_grant

        connection_id = connection.id
        grants_after_first = AccessGrant.count
        connections_after_first = LibraryConnection.count

        # Re-redeem the identical code for the same User (Req 5.9).
        second = InviteManager.redeem(invite_code: remote_code(token, remote_host), user: user)

        assert second.success?, "repeat cross-server redemption should report success"
        assert_not_nil second.connection
        assert_nil second.access_grant
        assert_equal connection_id, second.connection.id,
          "repeat cross-server redemption did not reuse the existing Library_Connection"
        assert_equal connections_after_first, LibraryConnection.count,
          "repeat cross-server redemption created a duplicate Library_Connection"
        assert_equal grants_after_first, AccessGrant.count,
          "repeat cross-server redemption created an Access_Grant"
      end
    end
  end

  private

  def create_local_grant(token:, library: libraries(:default_library))
    grant = AccessGrant.new(library: library, status: :active, expires_at: 7.days.from_now)
    grant.token = token
    grant.save!
    grant
  end

  def local_code(token)
    InviteManager.encode(server_base_url: BlackCandy.config.server_base_url, secret_token: token)
  end

  def remote_code(token, remote_host)
    InviteManager.encode(server_base_url: remote_host, secret_token: token)
  end

  def stub_confirm_success(remote_host, library_id:)
    stub_request(:post, "#{remote_host}/federation/grants/confirm").to_return(
      status: 200,
      body: { library: { id: library_id, name: "Shared Library" }, valid: true }.to_json,
      headers: { "Content-Type" => "application/json" }
    )
  end
end
