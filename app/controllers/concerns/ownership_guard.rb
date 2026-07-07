# frozen_string_literal: true

# OwnershipGuard
#
# Defensive before_action guard for actions that read or modify a
# Playback_Position_Record. Every position record is normally fetched through
# `Current.user.playback_positions`, so a record owned by another User — or one
# whose ownership metadata is missing or corrupted — can never legitimately
# enter that relation. This guard makes the guarantee explicit: if a targeted
# record's owning User cannot be resolved (a blank `user_id`, a `user_id` that
# references no User, or an owner other than the authenticated `Current.user`),
# the request is rejected with `BlackCandy::Forbidden` (403) before any read or
# write occurs, so corrupted ownership metadata never results in a read or
# write (Req 7.7).
#
# Including controllers wire the guard as a `before_action` (added automatically
# on include) and override `ownership_guarded_record` to return the record whose
# ownership must be verified. When there is nothing to guard yet — for example
# an upsert that has not loaded or built a record — the override returns nil and
# the guard is a no-op.
module OwnershipGuard
  extend ActiveSupport::Concern

  included do
    before_action :guard_record_ownership
  end

  private

  # before_action entry point: resolve the targeted record and guard it.
  def guard_record_ownership
    guard_ownership!(ownership_guarded_record)
  end

  # Reject with `BlackCandy::Forbidden` when `record` exists but its owning User
  # cannot be resolved. A nil record is a no-op: there is nothing to read or
  # modify, so there is nothing to guard.
  def guard_ownership!(record)
    return if record.nil?

    raise BlackCandy::Forbidden unless owner_resolvable?(record)
  end

  # Controllers including OwnershipGuard override this to return the
  # Playback_Position_Record being read or modified. Defaults to nil so the
  # guard stays inert until a target is provided.
  def ownership_guarded_record
    nil
  end

  # A record's owner is resolvable only when the record carries a present
  # `user_id`, that `user_id` references an existing User, and that User is the
  # authenticated `Current.user`. Any other case is treated as missing,
  # corrupted, or unauthorized ownership metadata.
  def owner_resolvable?(record)
    return false unless record.respond_to?(:user_id)
    return false if record.user_id.blank?

    owner = record.user
    return false if owner.nil?

    Current.user.present? && owner.id == Current.user.id
  end
end
