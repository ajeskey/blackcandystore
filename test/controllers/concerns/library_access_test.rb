# frozen_string_literal: true

require "test_helper"

class LibraryAccessTest < ActiveSupport::TestCase
  # A minimal host that mixes in the concern so its private helpers can be
  # exercised in isolation, the same way a controller would use them.
  class Host
    include LibraryAccess

    public :authorized_libraries, :authorize_library!, :authorize_active_library, :authorize_grant!
  end

  setup do
    @host = Host.new
    @owner = users(:visitor1)
    @owned_library = libraries(:default_library)
    @owned_library.update!(owner: @owner)

    @other_library = libraries(:secondary_library)
    @other_library.update!(owner: users(:visitor2))
  end

  test "authorized_libraries returns the local libraries the user owns" do
    result = @host.authorized_libraries(@owner)

    assert_includes result, @owned_library
    assert_not_includes result, @other_library
  end

  test "authorized_libraries returns an empty relation for a nil user" do
    assert_empty @host.authorized_libraries(nil)
  end

  test "authorized_libraries returns empty when the user owns no libraries" do
    assert_empty @host.authorized_libraries(users(:admin))
  end

  test "authorize_library! passes for an authorized library" do
    assert_nil @host.authorize_library!(@owner, @owned_library)
  end

  test "authorize_library! raises Forbidden for an unauthorized library" do
    assert_raises(BlackCandy::Forbidden) do
      @host.authorize_library!(@owner, @other_library)
    end
  end

  test "authorize_library! raises Forbidden for a nil library" do
    assert_raises(BlackCandy::Forbidden) do
      @host.authorize_library!(@owner, nil)
    end
  end

  test "authorize_active_library returns the library for an authorized selection" do
    assert_equal @owned_library, @host.authorize_active_library(@owner, @owned_library)
  end

  test "authorize_active_library rejects an unauthorized selection, logs it, and leaves Active_Library unchanged" do
    @owner.update!(active_library: @owned_library)

    logged = []
    Rails.logger.stub(:warn, ->(message) { logged << message }) do
      assert_raises(BlackCandy::Forbidden) do
        @host.authorize_active_library(@owner, @other_library)
      end
    end

    # The rejected attempt is recorded in the logs (Req 3.9).
    assert_equal 1, logged.size
    assert_match(/Rejected Active_Library selection/, logged.first)
    assert_match(/library_id=#{@other_library.id}/, logged.first)

    # The current Active_Library is left unchanged (Req 3.6).
    assert_equal @owned_library, @owner.reload.active_library
  end

  test "authorize_active_library rejects a nil library selection, logs it, and leaves Active_Library unchanged" do
    @owner.update!(active_library: @owned_library)

    logged = []
    Rails.logger.stub(:warn, ->(message) { logged << message }) do
      assert_raises(BlackCandy::Forbidden) do
        @host.authorize_active_library(@owner, nil)
      end
    end

    # A nil (non-existent) selection is treated as unauthorized: it is logged
    # (Req 3.9) and rejected (Req 3.6).
    assert_equal 1, logged.size
    assert_match(/Rejected Active_Library selection/, logged.first)

    # The current Active_Library is left unchanged (Req 3.6).
    assert_equal @owned_library, @owner.reload.active_library
  end

  test "authorize_active_library rejection leaves a user with no Active_Library still unset" do
    # A user who owns no libraries has no recorded Active_Library and cannot
    # default to one either (default selection only applies with exactly one
    # accessible library, Req 3.5).
    no_library_user = users(:admin)
    assert_nil no_library_user.active_library

    assert_raises(BlackCandy::Forbidden) do
      @host.authorize_active_library(no_library_user, @other_library)
    end

    # The rejected selection does not create or change any Active_Library (Req 3.6).
    assert_nil no_library_user.reload.active_library
  end

  # --- authorize_grant! (federation authorization, Req 6.4/6.5/6.6/6.8, 7.3/7.4) ---

  # Build a persisted grant for `library` with a known plaintext token so the
  # test can present that exact token to `authorize_grant!`.
  def create_grant(library:, token:, status: "active", expires_at: nil)
    grant = AccessGrant.new(library: library, status: status, expires_at: expires_at)
    grant.token = token
    grant.save!
    grant
  end

  test "authorize_grant! returns the grant for a valid active grant matching the requested library" do
    grant = create_grant(library: @owned_library, token: "valid-token")

    assert_equal grant, @host.authorize_grant!("valid-token", @owned_library.id)
  end

  test "authorize_grant! accepts a non-expired grant with a future expiration" do
    grant = create_grant(library: @owned_library, token: "future-token", expires_at: 1.day.from_now)

    assert_equal grant, @host.authorize_grant!("future-token", @owned_library.id)
  end

  test "authorize_grant! rejects a token that matches no stored grant" do
    create_grant(library: @owned_library, token: "valid-token")

    assert_raises(BlackCandy::Forbidden) do
      @host.authorize_grant!("no-such-token", @owned_library.id)
    end
  end

  test "authorize_grant! rejects a blank token" do
    assert_raises(BlackCandy::Forbidden) do
      @host.authorize_grant!("", @owned_library.id)
    end
  end

  test "authorize_grant! rejects a revoked grant even when the token matches" do
    create_grant(library: @owned_library, token: "revoked-token", status: "revoked")

    assert_raises(BlackCandy::Forbidden) do
      @host.authorize_grant!("revoked-token", @owned_library.id)
    end
  end

  test "authorize_grant! rejects an expired grant even when the token matches" do
    create_grant(library: @owned_library, token: "expired-token", expires_at: 1.day.ago)

    assert_raises(BlackCandy::Forbidden) do
      @host.authorize_grant!("expired-token", @owned_library.id)
    end
  end

  test "authorize_grant! rejects a valid grant presented for the wrong library" do
    # A perfectly valid grant for one library must not authorize a different
    # library: the credential match alone is never sufficient (Req 6.8).
    create_grant(library: @owned_library, token: "valid-token")

    assert_raises(BlackCandy::Forbidden) do
      @host.authorize_grant!("valid-token", @other_library.id)
    end
  end
end
