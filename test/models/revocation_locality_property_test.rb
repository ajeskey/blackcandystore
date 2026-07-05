# frozen_string_literal: true

require "test_helper"

# Property-based test for Property 11 of the multi-server-library-sharing
# feature.
#
# Design property (multi-server-library-sharing, Property 11):
#   For any set of Access_Grants for a Local_Library, revoking one grant SHALL
#   set that grant's status to revoked and SHALL leave the state of every other
#   grant unchanged; revoking a grant that is already revoked SHALL leave it
#   revoked and report success without further change (Req 7.6, 7.7).
#
# Revocation lives in `InviteManager.revoke(access_grant:, owner:)`: it verifies
# the requesting owner owns the grant's Library, then flips only that grant's
# status to `revoked`. An already-revoked grant is returned unchanged (idempotent).
#
# This test generates a set of grants in mixed states (active/revoked) for a
# single owned local Library, records every grant's status beforehand, revokes
# one selected grant, and asserts:
#   * locality (Req 7.6)     -> only the target grant's status becomes revoked;
#                               every other grant is byte-for-byte unchanged.
#   * idempotency (Req 7.7)  -> re-revoking the (now revoked) target reports
#                               success (returns the grant, no error), leaves it
#                               revoked, and changes nothing further anywhere.
# The generated target is sometimes initially active and sometimes initially
# revoked, so both the state-changing and the idempotent branches are covered.
class RevocationLocalityPropertyTest < ActiveSupport::TestCase
  # A readable directory so freshly created local libraries pass media-path
  # validation (Req 1.3/1.4); the fixtures directory always exists.
  MEDIA_PATH = Rails.root.join("test", "fixtures", "files").to_s

  setup do
    @owner = users(:admin)
    @seq = 0
  end

  # Feature: multi-server-library-sharing, Property 11: Revocation is local and idempotent
  test "revoking one grant revokes only that grant and leaves every other grant unchanged, and re-revoking an already-revoked grant reports success without further change" do
    check_property(iterations: 120) do
      # One grant per entry: its initial status. At least one grant so there is
      # always a target to revoke. Runs in a Rantly instance (choose/range on self).
      grant_statuses = Array.new(range(1, 5)) { choose(:active, :revoked) }

      # Index of the grant to revoke; covers both active and revoked targets.
      target_index = range(0, grant_statuses.size - 1)

      [ grant_statuses, target_index ]
    end.check do |(grant_statuses, target_index)|
      reset_state

      library = create_local_library(owner: @owner)

      grants = grant_statuses.map.with_index do |status, i|
        create_grant(library: library, token: "tok-#{next_seq}", status: status.to_s)
      end

      target = grants[target_index]

      # Snapshot every grant's persisted status before the revocation so we can
      # detect any collateral change (Req 7.6).
      before = snapshot(grants)

      # --- Revoke the target grant. -----------------------------------------
      returned = InviteManager.revoke(access_grant: target, owner: @owner)

      # The revoked grant is returned as confirmation of success (Req 7.2).
      assert_equal target.id, returned.id,
        "expected revoke to return the targeted grant as confirmation"
      assert returned.revoked?,
        "expected the returned grant to be revoked"

      # The target's persisted status is revoked (Req 7.6 / 7.7).
      assert_equal "revoked", AccessGrant.find(target.id).status,
        "expected the target grant to be persisted as revoked"

      # Locality: every OTHER grant's status is unchanged from before (Req 7.6).
      after = snapshot(grants)
      before.each do |id, status|
        next if id == target.id

        assert_equal status, after[id],
          "expected non-target grant #{id} to keep status #{status.inspect}, was #{after[id].inspect}"
      end

      # --- Idempotency: re-revoke the already-revoked target (Req 7.7). ------
      returned_again = InviteManager.revoke(access_grant: target, owner: @owner)

      assert_equal target.id, returned_again.id,
        "expected re-revoke to report success by returning the same grant"
      assert returned_again.revoked?,
        "expected the re-revoked grant to still be revoked"
      assert_equal "revoked", AccessGrant.find(target.id).status,
        "expected the target grant to remain revoked after re-revocation"

      # Nothing anywhere changed relative to the post-first-revocation state.
      final = snapshot(grants)
      assert_equal after, final,
        "expected no grant to change state when re-revoking an already-revoked grant"
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

  # A local library owned by `owner` so ownership verification in revoke passes.
  def create_local_library(owner:)
    Library.create!(name: "Prop11-Local-#{next_seq}", kind: "local", media_path: MEDIA_PATH, owner: owner)
  end

  # Persist a grant for `library` with a known plaintext token in the given
  # initial status.
  def create_grant(library:, token:, status:)
    grant = AccessGrant.new(library: library, status: status, expires_at: 7.days.from_now)
    grant.token = token
    grant.save!
    grant
  end

  # Map of grant id => persisted status, read fresh from the database.
  def snapshot(grants)
    AccessGrant.where(id: grants.map(&:id)).pluck(:id, :status).to_h
  end
end
