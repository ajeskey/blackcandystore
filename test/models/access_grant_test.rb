# frozen_string_literal: true

require "test_helper"

class AccessGrantTest < ActiveSupport::TestCase
  setup do
    @library = libraries(:default_library)
  end

  def build_grant(token: "s3cret-token", **attrs)
    AccessGrant.new(library: @library, token: token, **attrs)
  end

  test "belongs to a library" do
    grant = build_grant
    assert_equal @library, grant.library
  end

  test "requires a library" do
    grant = AccessGrant.new(token: "abc")
    assert_not grant.valid?
    assert_includes grant.errors.attribute_names, :library
  end

  test "redeemer_user is optional (Req 5.1)" do
    grant = build_grant
    assert grant.valid?, grant.errors.full_messages.to_sentence
    assert_nil grant.redeemer_user
  end

  test "records the redeemer_user when set (Req 5.1)" do
    grant = build_grant(redeemer_user: users(:visitor1))
    assert grant.save
    assert_equal users(:visitor1), grant.reload.redeemer_user
  end

  test "defaults to active status (Req 7.2)" do
    grant = build_grant
    assert grant.active?
    assert_equal "active", grant.status
  end

  test "active and revoked scopes select by status (Req 7.2)" do
    active_grant = build_grant(token: "active-token")
    active_grant.save!
    revoked_grant = build_grant(token: "revoked-token", status: :revoked)
    revoked_grant.save!

    assert_includes AccessGrant.active, active_grant
    assert_not_includes AccessGrant.active, revoked_grant
    assert_includes AccessGrant.revoked, revoked_grant
    assert_not_includes AccessGrant.revoked, active_grant
  end

  # Token hashing and constant-time verification (design: credential/auth model).

  test "stores the token hashed rather than in plaintext" do
    grant = build_grant(token: "plaintext-secret")
    assert_not_nil grant.token_digest
    assert_not_equal "plaintext-secret", grant.token_digest
    assert_equal AccessGrant.digest("plaintext-secret"), grant.token_digest
  end

  test "requires a token_digest" do
    grant = AccessGrant.new(library: @library)
    assert_not grant.valid?
    assert_includes grant.errors.attribute_names, :token_digest
  end

  test "digest is deterministic for the same token and differs for different tokens" do
    assert_equal AccessGrant.digest("token-a"), AccessGrant.digest("token-a")
    assert_not_equal AccessGrant.digest("token-a"), AccessGrant.digest("token-b")
  end

  test "authenticate_token verifies with a constant-time comparison" do
    grant = build_grant(token: "correct-horse")
    assert grant.authenticate_token("correct-horse")
    assert_not grant.authenticate_token("wrong-token")
    assert_not grant.authenticate_token(nil)
    assert_not grant.authenticate_token("")
  end

  test "find_by_token returns the matching grant" do
    grant = build_grant(token: "lookup-token")
    grant.save!

    found = AccessGrant.find_by_token("lookup-token")
    assert_equal grant, found
  end

  test "find_by_token returns nil for an unknown or blank token" do
    build_grant(token: "known-token").save!

    assert_nil AccessGrant.find_by_token("does-not-exist")
    assert_nil AccessGrant.find_by_token(nil)
    assert_nil AccessGrant.find_by_token("")
  end

  # Expiration (Req 6.5).

  test "expired? is false when expires_at is in the future or nil" do
    assert_not build_grant(expires_at: 1.day.from_now).expired?
    assert_not build_grant(expires_at: nil).expired?
  end

  test "expired? is true when expires_at is in the past" do
    assert build_grant(expires_at: 1.second.ago).expired?
  end

  test "usable? is true only for an active, non-expired grant (Req 6.5)" do
    assert build_grant(status: :active, expires_at: 1.day.from_now).usable?
    assert_not build_grant(status: :revoked, expires_at: 1.day.from_now).usable?
    assert_not build_grant(status: :active, expires_at: 1.second.ago).usable?
  end
end
