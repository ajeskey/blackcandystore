# frozen_string_literal: true

# CatalogChange is the hosting-side change log. Each row records a single
# Catalog change (an upsert or a deletion) for a Local_Library, stamped with
# the library's `catalog_version` immediately after the change committed
# (Req 3.1, 3.4, 3.5). A redeeming server pulls the ordered deltas after its
# Sync_Cursor through the Changes_Since_API so ongoing synchronization only
# transfers what changed.
#
# An upsert row stores just the item's hosting-side id and type; the current
# metadata and associations are read live from the `Song`/`Album`/`Artist` row
# at serve time (Req 3.4). A deletion row is fully described by id + type
# because the underlying row is gone, so deletions carry no metadata (Req 3.5).
class CatalogChange < ApplicationRecord
  ITEM_TYPES = %w[song album artist].freeze
  CHANGE_TYPES = %w[upsert deletion].freeze

  # The AR model class backing each hosting-side item type, used to hydrate
  # upserts from their live rows with associations eager-loaded (Req 3.4).
  ITEM_MODELS = { "song" => Song, "album" => Album, "artist" => Artist }.freeze
  ITEM_INCLUDES = { "song" => [ :album, :artist ], "album" => [ :artist ], "artist" => [] }.freeze

  belongs_to :library

  validates :version, presence: true
  validates :item_id, presence: true
  validates :item_type, presence: true, inclusion: { in: ITEM_TYPES }
  validates :change_type, presence: true, inclusion: { in: CHANGE_TYPES }

  # A single entry in a changes-since page. For an upsert `record` is the live
  # hydrated `Song`/`Album`/`Artist` row the controller renders through the
  # existing jbuilder shapes; for a deletion `record` is nil and the entry is
  # fully described by `id` + `item_type` (Req 3.5).
  Change = Struct.new(:change_type, :item_type, :id, :record, keyword_init: true)

  # The result of a changes-since query. `catalog_version` is the version the
  # redeeming server is to adopt once it applies `changes` (Req 3.2). When
  # `full_sync_required` is true, `changes` is empty and no partial set is
  # returned (Req 3.7). `pagy` is the pagination object so the controller can
  # emit the same pagination headers as the rest of the Federation API.
  Result = Struct.new(:catalog_version, :full_sync_required, :changes, :pagy, keyword_init: true)

  # Return the ordered Catalog_Changes for `library` that occurred after
  # `cursor`, one `page` at a time, together with the `catalog_version` the
  # redeeming server is to adopt (Req 3.2).
  #
  # - Rows with `version > cursor` are returned ordered by `version` ascending
  #   (ties broken by id for a stable order), paginated via pagy.
  # - Each upsert is hydrated from its live row with associations eager-loaded
  #   (Req 3.4); deletions pass through by id + type (Req 3.5).
  # - When `cursor >= catalog_version` there is nothing after the cursor, so an
  #   empty change set is returned with the current version (Req 3.6).
  # - When `cursor` is below the retained log floor the host can no longer serve
  #   that cursor incrementally, so `full_sync_required: true` is returned with
  #   no partial change set (Req 3.7).
  def self.changes_since(library, cursor, page = 1)
    cursor = cursor.to_i
    page = [ page.to_i, 1 ].max
    current_version = library.catalog_version

    # Req 3.6: at or beyond the current version there are no later changes.
    return empty_result(current_version) if cursor >= current_version

    # Req 3.7: if the oldest retained change is newer than the first change the
    # redeemer still needs (`cursor + 1`), the deltas between them have been
    # compacted away and the cursor can no longer be served incrementally.
    floor = where(library_id: library.id).minimum(:version)
    return full_sync_result(current_version) if floor.nil? || floor > cursor + 1

    scope = where(library_id: library.id).where("version > ?", cursor).order(:version, :id)

    begin
      pagy = Pagy.new(count: scope.count, page: page)
    rescue Pagy::OverflowError
      # A page past the last one simply has no further changes to apply.
      return empty_result(current_version)
    end

    rows = scope.offset(pagy.offset).limit(pagy.limit).to_a
    changes = build_changes(library, rows)

    Result.new(
      catalog_version: current_version,
      full_sync_required: false,
      changes: changes,
      pagy: pagy
    )
  end

  def self.empty_result(current_version)
    Result.new(catalog_version: current_version, full_sync_required: false, changes: [], pagy: nil)
  end
  private_class_method :empty_result

  def self.full_sync_result(current_version)
    Result.new(catalog_version: current_version, full_sync_required: true, changes: [], pagy: nil)
  end
  private_class_method :full_sync_result

  # Turn ordered change-log rows into `Change` entries, hydrating each upsert
  # from its live row. Live rows are loaded per type in a single query each to
  # avoid N+1s, then mapped back in the log's original order (Req 3.4).
  def self.build_changes(library, rows)
    records_by_type = hydrate_records(library, rows)

    rows.filter_map do |row|
      if row.change_type == "deletion"
        Change.new(change_type: "deletion", item_type: row.item_type, id: row.item_id, record: nil)
      else
        record = records_by_type.dig(row.item_type, row.item_id)
        # An upsert whose live row is gone was superseded by a later deletion;
        # there is nothing to mirror, so drop it and let the deletion converge.
        next if record.nil?

        Change.new(change_type: "upsert", item_type: row.item_type, id: row.item_id, record: record)
      end
    end
  end
  private_class_method :build_changes

  # Load the live `Song`/`Album`/`Artist` rows referenced by the upsert changes,
  # grouped by item type and indexed by hosting-side id, with associations
  # eager-loaded so the controller can render them without N+1 queries.
  def self.hydrate_records(library, rows)
    ITEM_TYPES.each_with_object({}) do |item_type, memo|
      ids = rows.select { |row| row.change_type == "upsert" && row.item_type == item_type }.map(&:item_id)
      next if ids.empty?

      model = ITEM_MODELS[item_type]
      memo[item_type] = model
        .where(library_id: library.id, id: ids)
        .includes(ITEM_INCLUDES[item_type])
        .index_by(&:id)
    end
  end
  private_class_method :hydrate_records
end
