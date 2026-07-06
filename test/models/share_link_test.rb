# frozen_string_literal: true

require "test_helper"

# Unit tests for the ShareLink model (Req 4.2, 8.1). A Share_Link owns no
# credential of its own: it delegates its lifecycle entirely to a backing
# AccessGrant. These tests cover the polymorphic sessionable association, the
# belongs_to access_grant wiring, and the usable?/expired?/active?/revoked?
# delegation used by callers as the single source of link validity (Req 8.5).
class ShareLinkTest < ActiveSupport::TestCase
  setup do
    @host = users(:visitor1)
    @library = libraries(:default_library)
    @session = PartySession.create!(user: @host, shared_library_ids: [])
  end

  def build_grant(**attrs)
    AccessGrant.create!(library: @library, token: "share-#{SecureRandom.hex(4)}", **attrs)
  end

  def build_share_link(grant: build_grant, sessionable: @session)
    ShareLink.new(sessionable: sessionable, access_grant: grant)
  end

  # --- Association wiring --------------------------------------------------

  test "belongs polymorphically to the session it shares" do
    link = build_share_link
    assert link.save
    assert_equal @session, link.reload.sessionable
    assert_equal "PartySession", link.sessionable_type
  end

  test "belongs to an access grant" do
    grant = build_grant
    link = build_share_link(grant: grant)
    link.save!
    assert_equal grant, link.reload.access_grant
  end

  test "requires a sessionable" do
    link = ShareLink.new(access_grant: build_grant)
    assert_not link.valid?
    assert_includes link.errors.attribute_names, :sessionable
  end

  test "requires an access grant" do
    link = ShareLink.new(sessionable: @session)
    assert_not link.valid?
    assert_includes link.errors.attribute_names, :access_grant
  end

  test "the session exposes its share links through the has_many association" do
    link = build_share_link
    link.save!
    assert_includes @session.share_links, link
  end

  test "can back a Co_Listen_Session too" do
    co_listen = CoListenSession.create!(user: @host, shared_library_ids: [])
    link = ShareLink.create!(sessionable: co_listen, access_grant: build_grant)
    assert_equal co_listen, link.reload.sessionable
  end

  # --- Lifecycle delegation to the backing grant (Req 8.5) -----------------

  test "usable? tracks a usable backing grant" do
    link = build_share_link(grant: build_grant(status: :active, expires_at: 1.day.from_now))
    assert link.usable?
    assert link.active?
    assert_not link.expired?
    assert_not link.revoked?
  end

  test "a revoked backing grant makes the link unusable and revoked" do
    link = build_share_link(grant: build_grant(status: :revoked, expires_at: 1.day.from_now))
    assert_not link.usable?
    assert link.revoked?
  end

  test "an expired backing grant makes the link unusable and expired" do
    link = build_share_link(grant: build_grant(status: :active, expires_at: 1.second.ago))
    assert_not link.usable?
    assert link.expired?
  end

  test "delegation tolerates a nil access grant" do
    link = ShareLink.new(sessionable: @session)
    assert_nil link.usable?
    assert_nil link.revoked?
  end
end
