# frozen_string_literal: true

require "test_helper"

# Unit coverage for the OwnershipGuard concern (Req 7.7): a targeted
# Playback_Position_Record whose owning User cannot be resolved must be rejected
# with BlackCandy::Forbidden before any read or write occurs.
class OwnershipGuardTest < ActiveSupport::TestCase
  # A minimal host that mixes in the concern so its helpers can be exercised in
  # isolation, the same way a controller would. `before_action` is stubbed as a
  # no-op class method since the concern registers a callback on include.
  class Host
    def self.before_action(*); end

    include OwnershipGuard

    public :guard_ownership!, :owner_resolvable?
  end

  # A lightweight stand-in for a Playback_Position_Record: carries a `user_id`
  # and resolves its owning User through `user`, mirroring the belongs_to.
  Record = Struct.new(:user_id, :user)

  setup do
    @host = Host.new
    @owner = users(:visitor1)
    @other = users(:visitor2)
    Current.session = Session.new(user: @owner)
  end

  teardown do
    Current.session = nil
  end

  test "guard_ownership! passes for a record owned by the current user" do
    record = Record.new(@owner.id, @owner)

    assert_nil @host.guard_ownership!(record)
  end

  test "guard_ownership! is a no-op for a nil record" do
    assert_nil @host.guard_ownership!(nil)
  end

  test "guard_ownership! raises Forbidden when the user_id is blank" do
    record = Record.new(nil, nil)

    assert_raises(BlackCandy::Forbidden) do
      @host.guard_ownership!(record)
    end
  end

  test "guard_ownership! raises Forbidden when the user_id resolves to no User" do
    record = Record.new(@owner.id, nil)

    assert_raises(BlackCandy::Forbidden) do
      @host.guard_ownership!(record)
    end
  end

  test "guard_ownership! raises Forbidden when the owner is another User" do
    record = Record.new(@other.id, @other)

    assert_raises(BlackCandy::Forbidden) do
      @host.guard_ownership!(record)
    end
  end

  test "guard_ownership! raises Forbidden when there is no authenticated user" do
    Current.session = nil
    record = Record.new(@owner.id, @owner)

    assert_raises(BlackCandy::Forbidden) do
      @host.guard_ownership!(record)
    end
  end
end
