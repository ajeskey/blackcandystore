# frozen_string_literal: true

class Library < ApplicationRecord
  NAME_MAX_LENGTH = 255

  enum :kind, { local: "local", remote: "remote" }, default: :local
  enum :scan_state, { idle: "idle", syncing: "syncing", failed: "failed" }, default: :idle

  belongs_to :owner, class_name: "User", optional: true

  # A Remote_Library is reached through a Library_Connection on the redeeming
  # server; local libraries leave this null (Req 5.2, 6.2, 8.5).
  belongs_to :library_connection, optional: true

  has_many :songs
  has_many :albums
  has_many :artists

  # The hosting-side change log for this Local_Library. Each row stamps a
  # single catalog change with the `catalog_version` produced by that change
  # (Req 3.1). Removed with the library so a deleted library leaves no orphaned
  # change log behind.
  has_many :catalog_changes, dependent: :delete_all

  # Deleting a library tears down the content scoped to it. Its songs are
  # removed first, then album/artist cleanup runs with the same library-scoped
  # semantics as `Media.clean_up` so an album or artist is removed if and only
  # if no song remains associated with it after the deletion, and every
  # album/artist that still has a song is preserved (Req 2.4, 2.5). The
  # library's Access_Grants are removed as well (Req 1.6); the grants table is
  # introduced in a later phase, so that step is guarded to no-op safely until
  # the table exists.
  before_destroy :destroy_scoped_content

  # The Default_Library represents the pre-existing single collection derived
  # from `MEDIA_PATH` (Req 1.7). It is the fallback library that content is
  # associated with when no explicit library is provided.
  def self.default
    find_by(is_default: true)
  end

  # Reports whether any local library is currently being scanned. This is the
  # per-library replacement for the global `Media.syncing?` cache flag used by
  # the legacy whole-server sync (Req 2.6, 2.7).
  def self.scanning?
    local.syncing.exists?
  end

  # Trim surrounding whitespace so that the length and uniqueness checks operate
  # on the meaningful part of the name (Req 1.9).
  normalizes :name, with: ->(name) { name.strip }

  # Name must be present (rejects empty and whitespace-only) and at most 255
  # characters, and unique within the server case-insensitively (Req 1.2, 1.9, 1.10).
  validates :name, presence: true, length: { maximum: NAME_MAX_LENGTH }
  validates :name, uniqueness: { case_sensitive: false }, allow_blank: true

  # Local libraries are backed by a media path on the current server that must
  # exist and be readable (Req 1.3, 1.4, 1.11).
  validate :media_path_verifiable, if: :local?

  private

  # Remove the library's songs, then reuse the library-scoped `Media.clean_up`
  # to drop albums/artists that no longer have any song, delete the library's
  # Access_Grants, and clear any user's stale Active_Library selection that
  # points at this library (Req 1.6, 2.4, 2.5, 3.1, 3.5).
  def destroy_scoped_content
    nullify_active_library_selections
    songs.destroy_all
    # The library and its `catalog_changes` log are being torn down together, so
    # skip Catalog_Version bumping here — recording per-item deletions would only
    # orphan change rows against the library that is about to be deleted.
    Media.clean_up(library_id: id, record_changes: false)
    destroy_access_grants
  end

  # A deleted library must not leave any user pointing at it through
  # `active_library_id`. Nullify those selections in the application cascade so
  # the behavior is correct regardless of database-level foreign key support
  # (SQLite vs PostgreSQL) (Req 3.1, 3.5).
  def nullify_active_library_selections
    User.where(active_library_id: id).update_all(active_library_id: nil)
  end

  # The `access_grants` table lands in Phase 2. Guard against its absence so
  # deletion works today and cascades to grants once the table exists (Req 1.6).
  def destroy_access_grants
    return unless defined?(AccessGrant) && AccessGrant.table_exists?

    AccessGrant.where(library_id: id).delete_all
  end

  # Mirrors Setting#media_path_exist, with an added branch for the case where the
  # existence of the media path cannot be confirmed because the check itself
  # fails or times out (Req 1.11).
  def media_path_verifiable
    return if media_path.nil?

    errors.add(:media_path, :blank) and return if media_path.blank?

    path = File.expand_path(media_path)

    begin
      path_exists = File.exist?(path)
    rescue StandardError, Timeout::Error
      errors.add(:media_path, :not_verifiable) and return
    end

    errors.add(:media_path, :not_exist) and return unless path_exists
    errors.add(:media_path, :unreadable) unless File.readable?(path)
  end
end
