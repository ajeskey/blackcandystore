# frozen_string_literal: true

# CatalogVersioning is the hosting-side hook that keeps a Local_Library's
# `catalog_version` and its `catalog_changes` log in lock-step with the
# catalog (Req 3.1, 3.4, 3.5). It is called from the scan pipeline whenever a
# content change originates on the host — `Media.sync(:added｜:modified｜:removed)`
# and the album/artist orphan cleanup in `Media.clean_up` (that wiring lives in
# a separate task).
#
# Every recorded change does two things atomically:
#
#   1. Bumps the owning Local_Library's `catalog_version` so it increases
#      monotonically on every catalog change (Req 3.1).
#   2. Appends exactly one `CatalogChange` row stamped with the *new* version.
#
# The bump and the append run inside a single row-locked transaction, so the
# version stamped on the appended row is exactly the version this change
# produced even under concurrent writers — the log never skips or reuses a
# version and never advances without a matching row.
#
# An upsert records only the item's hosting-side id and type; the current
# metadata is read live from the `Song`/`Album`/`Artist` row at serve time
# (Req 3.4). A deletion records only the id and type because the underlying row
# is already gone (Req 3.5), which is why `record_deletion` takes the id and the
# owning library explicitly rather than an item instance.
module CatalogVersioning
  module_function

  # Record the creation or metadata update of a content item (Req 3.1, 3.4).
  # `item` is a live `Song`/`Album`/`Artist` row; its owning library, id, and
  # type are read from the row.
  def record_upsert(item)
    record_change(
      library: item.library,
      item_type: item_type_for(item),
      item_id: item.id,
      change_type: "upsert"
    )
  end

  # Record the removal of a content item (Req 3.1, 3.5). The item's row is gone
  # by the time a deletion is recorded, so the hosting-side id (`remote_id`),
  # its `type`, and its owning `library` are passed explicitly.
  def record_deletion(type:, remote_id:, library:)
    record_change(
      library: library,
      item_type: type.to_s,
      item_id: remote_id,
      change_type: "deletion"
    )
  end

  # Atomically bump the library's version and append the stamped change row.
  # `with_lock` opens a transaction and locks the library row so the version we
  # read after incrementing is the one we stamp onto the appended row, keeping
  # the version and the log in lock-step even under concurrent changes.
  def record_change(library:, item_type:, item_id:, change_type:)
    return if library.nil?

    library.with_lock do
      library.increment!(:catalog_version)

      CatalogChange.create!(
        library_id: library.id,
        version: library.catalog_version,
        item_type: item_type,
        item_id: item_id,
        change_type: change_type
      )
    end

    # Fire the best-effort Catalog_Nudge only after the version bump and log
    # append have committed (the `with_lock` transaction has returned), so a
    # nudged redeemer that pulls immediately sees the change this call produced
    # (Req 6.1). A single enqueue per recorded change keeps this simple; nudge
    # delivery is fire-and-forget and never required for correctness (Req 6.4),
    # so no enqueue failure can affect the recorded change.
    CatalogNudgeJob.perform_later(library.id)
  end
  private_class_method :record_change

  def item_type_for(item)
    item.class.name.underscore
  end
  private_class_method :item_type_for
end
