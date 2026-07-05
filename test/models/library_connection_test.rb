# frozen_string_literal: true

require "test_helper"

class LibraryConnectionTest < ActiveSupport::TestCase
  setup do
    @user = users(:admin)
  end

  def build_connection(**attrs)
    LibraryConnection.new(
      user: @user,
      server_base_url: "https://remote.example.com",
      remote_library_id: 42,
      grant_token: "remote-bearer-token",
      **attrs
    )
  end

  test "belongs to a user" do
    connection = build_connection
    assert_equal @user, connection.user
  end

  test "requires a user" do
    connection = build_connection(user: nil)
    assert_not connection.valid?
    assert_includes connection.errors.attribute_names, :user
  end

  test "defaults to active status" do
    connection = build_connection
    assert connection.active?
    assert_equal "active", connection.status
  end

  test "supports active, revoked and unavailable statuses" do
    assert build_connection(status: :active).active?
    assert build_connection(status: :revoked).revoked?
    assert build_connection(status: :unavailable).unavailable?
  end

  test "active/revoked/unavailable scopes select by status" do
    active = build_connection(remote_library_id: 1)
    active.save!
    revoked = build_connection(remote_library_id: 2, status: :revoked)
    revoked.save!
    unavailable = build_connection(remote_library_id: 3, status: :unavailable)
    unavailable.save!

    assert_includes LibraryConnection.active, active
    assert_includes LibraryConnection.revoked, revoked
    assert_includes LibraryConnection.unavailable, unavailable
    assert_not_includes LibraryConnection.active, revoked
  end

  test "encrypts the grant_token at rest (Req 6.2)" do
    connection = build_connection(grant_token: "super-secret-bearer")
    connection.save!

    assert_equal "super-secret-bearer", connection.reload.grant_token

    # The persisted ciphertext must not contain the plaintext token.
    raw = LibraryConnection.connection.select_value(
      "SELECT grant_token FROM library_connections WHERE id = #{connection.id}"
    )
    assert_not_equal "super-secret-bearer", raw
    assert_not_includes raw.to_s, "super-secret-bearer"
  end

  test "round-trips the decrypted grant_token" do
    connection = build_connection(grant_token: "another-token")
    connection.save!
    assert_equal "another-token", LibraryConnection.find(connection.id).grant_token
  end
end
