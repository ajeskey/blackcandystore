# frozen_string_literal: true

require "test_helper"

class InviteManagerTest < ActiveSupport::TestCase
  test "encode produces an unpadded Base64URL string" do
    code = InviteManager.encode(server_base_url: "https://example.com", secret_token: "abc123")

    assert_kind_of String, code
    refute_includes code, "="
    refute_includes code, "+"
    refute_includes code, "/"
  end

  test "decode reverses encode" do
    code = InviteManager.encode(server_base_url: "https://example.com", secret_token: "abc123")

    assert_equal(
      { server_base_url: "https://example.com", secret_token: "abc123" },
      InviteManager.decode(code)
    )
  end

  test "round-trips values containing URL-unsafe and unicode characters" do
    url = "https://例え.example.com:3000/path?x=1&y=2"
    token = "tok/with+special=chars_ünïcödé"

    assert_equal(
      { server_base_url: url, secret_token: token },
      InviteManager.decode(InviteManager.encode(server_base_url: url, secret_token: token))
    )
  end

  test "decode raises Malformed on nil" do
    assert_raises(InviteManager::Malformed) { InviteManager.decode(nil) }
  end

  test "decode raises Malformed on empty and whitespace-only input" do
    assert_raises(InviteManager::Malformed) { InviteManager.decode("") }
    assert_raises(InviteManager::Malformed) { InviteManager.decode("   ") }
  end

  test "decode raises Malformed on invalid Base64" do
    assert_raises(InviteManager::Malformed) { InviteManager.decode("not valid base64 !!!") }
  end

  test "decode raises Malformed when decoded content is not valid JSON" do
    not_json = Base64.urlsafe_encode64("this is not json", padding: false)

    assert_raises(InviteManager::Malformed) { InviteManager.decode(not_json) }
  end

  test "decode raises Malformed when JSON is not an object" do
    array_payload = Base64.urlsafe_encode64(JSON.generate([ 1, 2, 3 ]), padding: false)

    assert_raises(InviteManager::Malformed) { InviteManager.decode(array_payload) }
  end

  test "decode raises Malformed when required keys are missing" do
    missing_token = Base64.urlsafe_encode64(JSON.generate({ u: "https://example.com" }), padding: false)
    missing_url = Base64.urlsafe_encode64(JSON.generate({ t: "abc123" }), padding: false)

    assert_raises(InviteManager::Malformed) { InviteManager.decode(missing_token) }
    assert_raises(InviteManager::Malformed) { InviteManager.decode(missing_url) }
  end

  test "decode raises Malformed when required fields are not strings" do
    non_string = Base64.urlsafe_encode64(JSON.generate({ u: 123, t: false }), padding: false)

    assert_raises(InviteManager::Malformed) { InviteManager.decode(non_string) }
  end

  test "generate creates an active Access_Grant and returns a decodable Invite_Code" do
    library = libraries(:default_library)
    owner = users(:visitor1)

    assert_difference -> { AccessGrant.count }, 1 do
      @code = InviteManager.generate(library: library, owner: owner)
    end

    grant = AccessGrant.last
    assert_equal library, grant.library
    assert grant.active?

    decoded = InviteManager.decode(@code)
    assert_equal BlackCandy.config.server_base_url, decoded[:server_base_url]
    # The returned invite carries the plaintext token that authenticates the grant.
    assert grant.authenticate_token(decoded[:secret_token])
  end

  test "generate mints a 128-bit (16-byte hex) secret token" do
    code = InviteManager.generate(library: libraries(:default_library), owner: users(:visitor1))

    token = InviteManager.decode(code)[:secret_token]

    assert_equal 32, token.length # 16 bytes rendered as hex
    assert_match(/\A[0-9a-f]{32}\z/, token)
  end

  test "generate defaults expiration to 7 days after creation" do
    freeze_time do
      InviteManager.generate(library: libraries(:default_library), owner: users(:visitor1))

      assert_in_delta (Time.current + 7.days).to_f, AccessGrant.last.expires_at.to_f, 1
    end
  end

  test "generate honors an explicit in-range expiration duration" do
    freeze_time do
      InviteManager.generate(library: libraries(:default_library), owner: users(:visitor1), expires_in: 30.days)

      assert_in_delta (Time.current + 30.days).to_f, AccessGrant.last.expires_at.to_f, 1
    end
  end

  test "generate accepts the inclusive expiration boundaries" do
    assert_difference -> { AccessGrant.count }, 2 do
      InviteManager.generate(library: libraries(:default_library), owner: users(:visitor1), expires_in: 1.minute)
      InviteManager.generate(library: libraries(:default_library), owner: users(:visitor1), expires_in: 365.days)
    end
  end

  test "generate rejects a non-owner without creating an Access_Grant" do
    assert_no_difference -> { AccessGrant.count } do
      assert_raises(BlackCandy::Forbidden) do
        InviteManager.generate(library: libraries(:default_library), owner: users(:visitor2))
      end
    end
  end

  test "generate rejects a library owned by no one" do
    assert_no_difference -> { AccessGrant.count } do
      assert_raises(BlackCandy::Forbidden) do
        InviteManager.generate(library: libraries(:secondary_library), owner: users(:visitor1))
      end
    end
  end

  test "generate rejects a non-existent library without creating an Access_Grant" do
    unpersisted = Library.new(name: "Ghost", kind: "local", owner: users(:visitor1))

    assert_no_difference -> { AccessGrant.count } do
      assert_raises(InviteManager::LibraryNotFound) do
        InviteManager.generate(library: unpersisted, owner: users(:visitor1))
      end
      assert_raises(InviteManager::LibraryNotFound) do
        InviteManager.generate(library: nil, owner: users(:visitor1))
      end
    end
  end

  test "generate rejects an expiration shorter than 1 minute without creating an Access_Grant" do
    assert_no_difference -> { AccessGrant.count } do
      assert_raises(InviteManager::InvalidExpiration) do
        InviteManager.generate(library: libraries(:default_library), owner: users(:visitor1), expires_in: 59.seconds)
      end
    end
  end

  test "generate rejects an expiration longer than 365 days without creating an Access_Grant" do
    assert_no_difference -> { AccessGrant.count } do
      assert_raises(InviteManager::InvalidExpiration) do
        InviteManager.generate(library: libraries(:default_library), owner: users(:visitor1), expires_in: 366.days)
      end
    end
  end

  # --- redeem: malformed (Req 5.3) -------------------------------------------

  test "redeem raises Malformed on an undecodable invite code" do
    assert_raises(InviteManager::Malformed) do
      InviteManager.redeem(invite_code: "not a valid code !!!", user: users(:visitor1))
    end
  end

  # --- redeem: local path (Req 5.1, 5.4, 5.5, 5.6) ---------------------------

  test "redeem grants access to a local library and records the redemption" do
    token = "local-secret-token"
    grant = create_local_grant(token: token)
    user = users(:visitor2)

    result = InviteManager.redeem(invite_code: local_code(token), user: user)

    assert result.success?
    assert_equal libraries(:default_library), result.library
    assert_equal grant, result.access_grant
    assert_nil result.connection

    grant.reload
    assert_equal user.id, grant.redeemer_user_id
    assert_not_nil grant.redeemed_at
  end

  test "redeem rejects a revoked local grant with an authorization error" do
    token = "revoked-token"
    grant = create_local_grant(token: token, status: :revoked)

    assert_raises(InviteManager::Revoked) do
      InviteManager.redeem(invite_code: local_code(token), user: users(:visitor2))
    end

    assert_nil grant.reload.redeemer_user_id
  end

  test "redeem rejects an unknown local token with an authorization error" do
    assert_raises(InviteManager::Revoked) do
      InviteManager.redeem(invite_code: local_code("no-such-token"), user: users(:visitor2))
    end
  end

  test "redeem rejects a first-time expired local redemption" do
    token = "expired-token"
    grant = create_local_grant(token: token, expires_at: 1.hour.ago)

    assert_raises(InviteManager::Expired) do
      InviteManager.redeem(invite_code: local_code(token), user: users(:visitor2))
    end

    assert_nil grant.reload.redeemer_user_id
  end

  # --- redeem: local idempotency (Req 5.6) -----------------------------------

  test "redeem is idempotent for a non-revoked grant already redeemed by the same user" do
    token = "idempotent-token"
    user = users(:visitor2)
    grant = create_local_grant(token: token)

    InviteManager.redeem(invite_code: local_code(token), user: user)
    first_redeemed_at = grant.reload.redeemed_at

    assert_no_difference -> { AccessGrant.count } do
      result = InviteManager.redeem(invite_code: local_code(token), user: user)
      assert result.success?
    end

    # Access is left unchanged on the repeat redemption (Req 5.6).
    assert_equal first_redeemed_at.to_f, grant.reload.redeemed_at.to_f
  end

  test "redeem reports success for an expired code the same user already redeemed" do
    token = "already-redeemed-expired"
    user = users(:visitor2)
    grant = create_local_grant(token: token, expires_at: 1.hour.from_now)

    InviteManager.redeem(invite_code: local_code(token), user: user)

    # The code expires after the initial redemption.
    grant.update!(expires_at: 1.hour.ago)

    result = InviteManager.redeem(invite_code: local_code(token), user: user)
    assert result.success?
    assert_equal libraries(:default_library), result.library
  end

  # --- redeem: cross-server path (Req 5.2, 5.7, 5.8, 5.9) --------------------

  REMOTE_BASE_URL = "https://remote.example.com"
  REMOTE_CONFIRM_URL = "https://remote.example.com/federation/grants/confirm"

  test "redeem confirms a cross-server grant and creates a single Library_Connection" do
    token = "remote-secret"
    stub_confirm_success(library_id: 42, name: "Shared Library")
    user = users(:visitor2)

    result = nil
    assert_difference -> { LibraryConnection.count }, 1 do
      result = InviteManager.redeem(invite_code: remote_code(token), user: user)
    end

    assert result.success?
    connection = result.connection
    assert_not_nil connection
    assert_equal user, connection.user
    assert_equal REMOTE_BASE_URL, connection.server_base_url
    assert_equal 42, connection.remote_library_id
    assert_equal token, connection.grant_token
    assert connection.active?
  end

  test "redeem reuses an existing connection and never creates a duplicate" do
    token = "remote-secret-dedupe"
    stub_confirm_success(library_id: 7, name: "Shared Library")
    user = users(:visitor2)

    first = InviteManager.redeem(invite_code: remote_code(token), user: user)

    assert_no_difference -> { LibraryConnection.count } do
      second = InviteManager.redeem(invite_code: remote_code(token), user: user)
      assert_equal first.connection.id, second.connection.id
    end
  end

  test "redeem rejects a cross-server grant the issuing server reports invalid" do
    token = "remote-revoked"
    stub_request(:post, REMOTE_CONFIRM_URL).to_return(status: 403, body: "")

    assert_no_difference -> { LibraryConnection.count } do
      assert_raises(InviteManager::Revoked) do
        InviteManager.redeem(invite_code: remote_code(token), user: users(:visitor2))
      end
    end
  end

  test "redeem rejects a cross-server grant when the issuing server reports not valid" do
    token = "remote-not-valid"
    stub_request(:post, REMOTE_CONFIRM_URL)
      .to_return(status: 200, body: { valid: false }.to_json, headers: { "Content-Type" => "application/json" })

    assert_no_difference -> { LibraryConnection.count } do
      assert_raises(InviteManager::Revoked) do
        InviteManager.redeem(invite_code: remote_code(token), user: users(:visitor2))
      end
    end
  end

  test "redeem rejects a cross-server redemption when the issuing server is unreachable" do
    token = "remote-unreachable"
    stub_request(:post, REMOTE_CONFIRM_URL).to_raise(Errno::ECONNREFUSED)

    assert_no_difference -> { LibraryConnection.count } do
      assert_raises(InviteManager::ServerUnavailable) do
        InviteManager.redeem(invite_code: remote_code(token), user: users(:visitor2))
      end
    end
  end

  test "redeem rejects a cross-server redemption when the issuing server times out" do
    token = "remote-timeout"
    stub_request(:post, REMOTE_CONFIRM_URL).to_timeout

    assert_no_difference -> { LibraryConnection.count } do
      assert_raises(InviteManager::ServerUnavailable) do
        InviteManager.redeem(invite_code: remote_code(token), user: users(:visitor2))
      end
    end
  end

  # --- access_list (Req 7.1, 7.5) --------------------------------------------

  test "access_list returns every grant for a library the owner owns" do
    grant1 = create_local_grant(token: "list-token-1")
    grant2 = create_local_grant(token: "list-token-2")

    grants = InviteManager.access_list(library: libraries(:default_library), owner: users(:visitor1))

    assert_equal [ grant1.id, grant2.id ].sort, grants.map(&:id).sort
    # Each grant carries its redemption status and expiration (Req 7.1).
    grants.each do |grant|
      assert_respond_to grant, :status
      assert_respond_to grant, :redeemed_at
      assert_respond_to grant, :expires_at
    end
  end

  test "access_list returns an empty collection when the library has no grants" do
    grants = InviteManager.access_list(library: libraries(:default_library), owner: users(:visitor1))

    assert_empty grants
  end

  test "access_list excludes grants belonging to other libraries" do
    own_grant = create_local_grant(token: "own-grant")
    create_local_grant(token: "other-grant", library: libraries(:secondary_library))

    grants = InviteManager.access_list(library: libraries(:default_library), owner: users(:visitor1))

    assert_equal [ own_grant.id ], grants.map(&:id)
  end

  test "access_list rejects a non-owner with an authorization error" do
    create_local_grant(token: "guarded-token")

    assert_raises(BlackCandy::Forbidden) do
      InviteManager.access_list(library: libraries(:default_library), owner: users(:visitor2))
    end
  end

  # --- revoke (Req 7.2, 7.5, 7.6, 7.7, 7.8) ----------------------------------

  test "revoke marks a grant revoked and returns it as confirmation" do
    grant = create_local_grant(token: "to-revoke")

    result = InviteManager.revoke(access_grant: grant, owner: users(:visitor1))

    assert_equal grant, result
    assert grant.reload.revoked?
  end

  test "revoke is idempotent on an already-revoked grant and reports success" do
    grant = create_local_grant(token: "already-revoked", status: :revoked)

    assert_no_difference -> { AccessGrant.where(status: "revoked").count } do
      result = InviteManager.revoke(access_grant: grant, owner: users(:visitor1))
      assert_equal grant, result
    end

    assert grant.reload.revoked?
  end

  test "revoke leaves every other grant for the library unchanged" do
    target = create_local_grant(token: "revoke-target")
    other = create_local_grant(token: "keep-active")

    InviteManager.revoke(access_grant: target, owner: users(:visitor1))

    assert other.reload.active?
  end

  test "revoke rejects a non-owner with an authorization error and leaves the grant unchanged" do
    grant = create_local_grant(token: "protected-grant")

    assert_raises(BlackCandy::Forbidden) do
      InviteManager.revoke(access_grant: grant, owner: users(:visitor2))
    end

    assert grant.reload.active?
  end

  test "revoke raises GrantNotFound for a nil grant" do
    assert_raises(InviteManager::GrantNotFound) do
      InviteManager.revoke(access_grant: nil, owner: users(:visitor1))
    end
  end

  private

  def create_local_grant(token:, status: :active, expires_at: 7.days.from_now, library: libraries(:default_library))
    grant = AccessGrant.new(library: library, status: status, expires_at: expires_at)
    grant.token = token
    grant.save!
    grant
  end

  def local_code(token)
    InviteManager.encode(server_base_url: BlackCandy.config.server_base_url, secret_token: token)
  end

  def remote_code(token)
    InviteManager.encode(server_base_url: REMOTE_BASE_URL, secret_token: token)
  end

  def stub_confirm_success(library_id:, name:)
    stub_request(:post, REMOTE_CONFIRM_URL).to_return(
      status: 200,
      body: { library: { id: library_id, name: name }, valid: true }.to_json,
      headers: { "Content-Type" => "application/json" }
    )
  end
end
