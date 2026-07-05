# frozen_string_literal: true

class Media
  include Singleton
  include Turbo::Broadcastable
  extend ActiveModel::Naming

  class << self
    def sync(type, file_paths = [], library_id: nil)
      return if file_paths.blank?

      library_id ||= Library.default&.id

      case type
      when :added
        add_files(file_paths, library_id)
      when :removed
        remove_files(file_paths, library_id)
      when :modified
        remove_files(file_paths, library_id)
        add_files(file_paths, library_id)
      end
    end

    def syncing?
      Rails.cache.fetch("media_syncing") { false }
    end

    def syncing=(is_syncing)
      return if is_syncing == syncing?
      Rails.cache.write("media_syncing", is_syncing, expires_in: 1.hour)
    end

    def clean_up(file_hashes = [], library_id: nil, record_changes: true)
      # Scope every clean-up query to the given library so an album/artist is
      # removed if and only if no song remains for it *within that library*
      # (Req 2.4, 2.5). When no library is given, fall back to global scope to
      # preserve the pre-feature behavior.
      song_scope = library_id ? Song.where(library_id: library_id) : Song.all
      album_scope = library_id ? Album.where(library_id: library_id) : Album.all
      artist_scope = library_id ? Artist.where(library_id: library_id) : Artist.all

      if file_hashes.present?
        removed_songs = song_scope.where.not(md5_hash: file_hashes).destroy_all
        record_catalog_deletions(removed_songs, "song") if record_changes
      end

      # Clean up no content albums and artist. Recording the orphan cleanup as
      # deletion Catalog_Changes keeps a Local_Library's catalog_version and
      # change log in lock-step with the catalog (Req 3.1, 3.5). Teardown of a
      # whole Library passes `record_changes: false` because the library and its
      # change log are being discarded together, so per-item deletions would
      # only orphan change rows against the vanishing library.
      removed_albums = album_scope.where.missing(:songs).destroy_all
      record_catalog_deletions(removed_albums, "album") if record_changes

      removed_artists = artist_scope.where.missing(:songs, :albums).destroy_all
      record_catalog_deletions(removed_artists, "artist") if record_changes
    end

    def fetch_external_metadata
      return unless Setting.discogs_token.present?

      jobs = []

      Artist.lack_metadata.find_each do |artist|
        jobs << AttachCoverImageFromDiscogsJob.new(artist)
      end

      Album.lack_metadata.find_each do |album|
        jobs << AttachCoverImageFromDiscogsJob.new(album)
      end

      ActiveJob.perform_all_later(jobs)
    end

    private

    def add_files(file_paths, library_id = nil)
      file_paths.map do |file_path|
        file_info = MediaFile.file_info(file_path)
        song = attach(file_info, library_id)
        next unless song

        # The content change has committed at this point, so record the created
        # or metadata-updated song as an upsert Catalog_Change (Req 3.1, 3.4).
        record_catalog_upsert(song)
        file_info[:md5_hash]
      rescue
        next
      end.compact
    end

    def remove_files(file_paths, library_id = nil)
      file_path_hashes = file_paths.map { |file_path| MediaFile.get_md5_hash(file_path) }

      songs = library_id ? Song.where(library_id: library_id) : Song.all
      removed_songs = songs.where(file_path_hash: file_path_hashes).destroy_all
      record_catalog_deletions(removed_songs, "song")

      clean_up(library_id: library_id)
    end

    # Record a content item's creation or metadata update as an upsert
    # Catalog_Change, bumping its owning Local_Library's catalog_version
    # (Req 3.1, 3.4). Only Local_Library content participates: the mirror on the
    # redeeming side is driven by CatalogSync, not the scan pipeline, so remote
    # (mirror) content MUST NOT bump a hosting-side version. Versioning failures
    # never disrupt the scan.
    def record_catalog_upsert(item)
      return unless item&.library&.local?

      CatalogVersioning.record_upsert(item)
    rescue => error
      Rails.logger.error("CatalogVersioning.record_upsert failed: #{error.message}")
    end

    # Record each removed content item as a deletion Catalog_Change, bumping its
    # owning Local_Library's catalog_version (Req 3.1, 3.5). The records have
    # already been destroyed, so their id and library are read from the in-memory
    # rows. Remote (mirror) content is skipped for the same reason as upserts.
    def record_catalog_deletions(records, item_type)
      Array(records).each do |record|
        library = record.library
        next unless library&.local?

        CatalogVersioning.record_deletion(type: item_type, remote_id: record.id, library: library)
      rescue => error
        Rails.logger.error("CatalogVersioning.record_deletion failed: #{error.message}")
      end
    end

    # Content creation is scoped to a library so the artist/album/song lookups
    # use the library-scoped uniqueness keys from the schema
    # (`(library_id, name)`, `(library_id, artist_id, name)`, and
    # `(library_id, md5_hash)`). The same media file under two libraries
    # therefore yields two separate songs (Req 2.1, 2.3).
    def attach(file_info, library_id = nil)
      artist = Artist.create_or_find_by!(
        name: file_info[:artist_name] || Artist::UNKNOWN_NAME,
        library_id: library_id
      )

      various_artist = Artist.create_or_find_by!(various: true, library_id: library_id) if various_artist?(file_info)

      album = Album.create_or_find_by!(
        artist_id: various_artist&.id || artist.id,
        name: file_info[:album_name] || Album::UNKNOWN_NAME,
        library_id: library_id
      )

      album.update!(album_info(file_info))

      unless album.has_cover_image?
        album.cover_image.attach(file_info[:image]) if file_info[:image].present?
      end

      Song.create_or_find_by!(md5_hash: file_info[:md5_hash], library_id: library_id) do |item|
        item.attributes = song_info(file_info).merge(album_id: album.id, artist_id: artist.id)
      end
    end

    def song_info(file_info)
      file_info.slice(:name, :tracknum, :discnum, :duration, :file_path, :file_path_hash, :bit_depth).compact
    end

    def album_info(file_info)
      file_info.slice(:year, :genre).compact
    end

    def various_artist?(file_info)
      albumartist = file_info[:albumartist_name]
      albumartist.present? && (albumartist.casecmp("various artists").zero? || albumartist != file_info[:artist_name])
    end
  end
end
