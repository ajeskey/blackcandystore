# frozen_string_literal: true

# Scans a single Local_Library's media path and associates every discovered
# song/album/artist with that library (Req 2.1). It generalizes the legacy
# whole-server `MediaSyncAllJob` (which scans one global `MEDIA_PATH`) to run
# per-library.
#
# Scan progress is tracked with the library's own `scan_state` column
# (`idle｜syncing｜failed`), replacing the global `Media.syncing?` cache flag:
# `syncing` while a scan is in progress (Req 2.6), `idle` once it completes
# (Req 2.7), and `failed` when a scan terminates before completing (Req 2.8).
# Each state transition is broadcast so the UI reflects the current status.
class LibraryScanJob < MediaSyncJob
  def perform(library_id)
    @library = Library.local.find(library_id)

    start_scan

    file_paths = MediaFile.file_paths(@library.media_path)
    file_md5_hashes = Parallel.map(file_paths, in_processes: self.class.parallel_processor_count) do |file_path|
      MediaFile.get_md5_hash(file_path, with_mtime: true)
    end

    # `existing_songs` is intentionally kept as a lazy relation: it is queried
    # again (below) after new songs have been created so the clean-up step sees
    # the full set of current md5 hashes for this library and does not remove
    # freshly added songs. This mirrors `MediaSyncAllJob`.
    existing_songs = @library.songs.where(md5_hash: file_md5_hashes)
    added_file_paths = file_paths - existing_songs.pluck(:file_path)
    added_song_hashes = added_file_paths.blank? ? [] : parallel_sync(:added, added_file_paths, library_id: @library.id).flatten.compact

    Media.clean_up(added_song_hashes + existing_songs.pluck(:md5_hash), library_id: @library.id)

    complete_scan
  ensure
    # If the library is still marked `syncing` here, the scan terminated before
    # reaching `complete_scan` (an exception was raised, or the worker was
    # killed mid-scan) — record the scan failure (Req 2.8).
    fail_scan_if_interrupted
  end

  private

  # Req 2.6 — report the library as syncing for the duration of the scan.
  def start_scan
    @library.update!(scan_state: :syncing)
    broadcast_scan_state
  end

  # Req 2.7 — report the library as no longer syncing once the scan completes.
  def complete_scan
    @library.update!(scan_state: :idle)
    broadcast_scan_state
  end

  # Req 2.8 — stop reporting the library as syncing and record the failure.
  def fail_scan_if_interrupted
    return unless @library&.reload&.syncing?

    @library.update(scan_state: :failed)
    broadcast_scan_state
  end

  def broadcast_scan_state
    Media.instance.broadcast_render_to(
      "media_sync",
      partial: "media_syncing/syncing",
      locals: { syncing: Library.scanning? }
    )
  end

  # LibraryScanJob tracks scan progress via each library's `scan_state` column
  # plus a broadcast, so it deliberately does not toggle the global
  # `Media.syncing?` cache flag used by the legacy whole-server sync.
  def before_sync; end

  def after_sync(fetch_external_metadata: true)
    Media.fetch_external_metadata if fetch_external_metadata
  end
end
