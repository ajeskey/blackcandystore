# frozen_string_literal: true

# Path_Resolver is the component behind Requirements 8, 9 and 10. It classifies
# where a piece of content is served from (its source) and produces the resolved
# path the Web_Player and App_Player fetch from, so the players never need any
# library-specific logic (the resolved path is always same-origin from the
# player's perspective).
#
# This file currently implements stream resolution (`resolve_stream`). Asset
# resolution (`resolve_asset`) is added in a later task and reuses the shared
# classification helpers defined here.
class PathResolver
  # Route helpers so the resolver can build the current-server streaming paths
  # the app has always used (`new_stream_path` / `new_transcoded_stream_path`).
  include Rails.application.routes.url_helpers

  STREAM_SOURCE_LOCAL = "local"
  STREAM_SOURCE_REMOTE = "remote"

  # Asset_Source classifications mirror the stream sources: `local` when the
  # owning Album/Artist lives in a Local_Library on the current server and
  # `remote` when it lives in a Remote_Library reached through a
  # Library_Connection (Req 9.1).
  ASSET_SOURCE_LOCAL = "local"
  ASSET_SOURCE_REMOTE = "remote"

  # Same-origin proxy path the redeeming server maps to the hosting server's
  # federation streaming endpoint (Req 8.5). The proxy endpoint itself is a
  # later task; here we only produce the path.
  REMOTE_STREAM_PATH_PREFIX = "/stream/remote"

  # Same-origin proxy path prefix for a Remote_Library's cover image, analogous
  # to REMOTE_STREAM_PATH_PREFIX. The redeeming server maps this to the hosting
  # server's federation asset endpoint through the Library_Connection (Req 9.4);
  # the proxy endpoint itself is wired in a later task, here we only produce the
  # path.
  REMOTE_ASSET_PATH_PREFIX = "/asset/remote"

  # The cover-image variants declared on ImageableConcern.
  ASSET_VARIANTS = %i[small medium large].freeze

  # The variant used when a caller does not request a specific one, matching the
  # default size used by `ApplicationHelper#cover_image_url_for`.
  DEFAULT_ASSET_VARIANT = :medium

  # Classify a Song's Stream_Source and produce its Resolved_Stream_Path.
  #
  # - A Song whose Library is a Local_Library (including the Default_Library) or
  #   whose Library association cannot be determined resolves to `local`, using
  #   the existing current-server stream path (Req 8.1, 8.4, 8.8, 8.9).
  # - A Song whose Library is a Remote_Library resolves to `remote`. When its
  #   Library_Connection can be reached, the path is the same-origin proxy URL
  #   (Req 8.5); when the connection cannot be resolved to a streaming endpoint,
  #   the path is empty and the Song is marked unavailable while every other
  #   attribute is left untouched (Req 8.11).
  #
  # `transcode` mirrors `SongHelper#song_json_builder`: when the client needs a
  # transcoded stream the transcoded variant path is used. The transcode
  # decision itself (`need_transcode?`) depends on client detection and stays in
  # the request layer, which passes the result in here.
  #
  # When the same content is reachable from more than one accessible source —
  # i.e. the Song belongs to a Duplicate_Group with more than one member Song —
  # the copy chosen by the User's Source_Preference is resolved instead of the
  # passed Song, and the stream is resolved for that selected copy (Req 8.13,
  # 12.6). `SourcePreference.select` already filters to AVAILABLE copies and
  # applies the preference ordering, so falling back to the next available
  # source is inherent in the selection (Req 11.6, 12.7); when no accessible
  # copy remains it returns nil and we fall back to the passed Song, which then
  # resolves as unavailable (empty path) (Req 11.9). A Song with no
  # Duplicate_Group or a single-member group resolves exactly as before
  # (backward compatible).
  #
  # `select_source: false` resolves the passed Song directly without consulting
  # Source_Preference. `SourcePreference.select` uses this path for its
  # availability checks so that resolution stays a pure per-Song classification
  # and selection never re-enters itself.
  #
  # Returns a hash: { stream_source:, resolved_stream_path:, available: }.
  def resolve_stream(song, user: nil, transcode: false, select_source: true)
    target = select_source ? preferred_source(song, user: user) : song

    if remote?(target)
      resolve_remote_stream(target)
    else
      resolve_local_stream(target, transcode: transcode)
    end
  end

  # Classify an Album's or Artist's cover image Asset_Source and produce its
  # Resolved_Asset_Path. The player and API never need library-specific logic:
  # a `local` path is always same-origin on the current server and a `remote`
  # path is a same-origin proxy the redeeming server maps to the hosting
  # server's asset endpoint.
  #
  # - A record whose Library is a Local_Library (including the Default_Library)
  #   or whose Library association cannot be determined is classified `local`.
  #   When it has a cover image the path is the current-server cover-image URL
  #   the app has always produced (the ActiveStorage proxy path), matching
  #   pre-existing local cover images (Req 9.1, 9.3, 9.5).
  # - A record whose Library is a Remote_Library is classified `remote`. When
  #   its Library_Connection can be reached and a cover image is present the path
  #   is the same-origin asset proxy URL (Req 9.4); when the connection cannot be
  #   resolved to an asset endpoint the path is empty and the cover image is
  #   marked unavailable while every other attribute is left untouched (Req 9.8).
  # - For either source, when no cover image is available the path is empty and
  #   the cover image is indicated absent (Req 9.7).
  #
  # `variant` is one of :small/:medium/:large (defaulting to :medium); it selects
  # the current-server variant path and is forwarded to the remote asset
  # endpoint (Req 9.4).
  #
  # Returns a hash:
  #   { asset_source:, resolved_asset_path:, available:, present: }
  # where `present` indicates whether a cover image exists for the record and
  # `available` indicates whether the asset source could be resolved.
  def resolve_asset(record, user: nil, variant: nil)
    if remote?(record)
      resolve_remote_asset(record, variant: variant)
    else
      resolve_local_asset(record, variant: normalize_variant(variant))
    end
  end

  private

  # The copy of the Song's content the User's Source_Preference selects, when
  # the content is reachable from more than one accessible source. Only a
  # Duplicate_Group with more than one member Song represents such content; a
  # missing or single-member group leaves the passed Song untouched so
  # single-source resolution behaves exactly as before (Req 8.13, 12.6). When
  # every copy is unavailable `SourcePreference.select` returns nil and the
  # passed Song is used, which resolves as unavailable (Req 11.9).
  def preferred_source(song, user:)
    group = song.duplicate_group
    return song unless multi_source_group?(group)

    SourcePreference.select(group, user: user) || song
  end

  # A Duplicate_Group only offers a choice of source when it has more than one
  # member Song (Req 8.13).
  def multi_source_group?(group)
    group.present? && group.songs.size > 1
  end

  # A record is served remotely only when it belongs to a Remote_Library. A nil
  # (undeterminable) association is treated as local (Req 8.9).
  def remote?(record)
    library = record.library
    library.present? && library.remote?
  end

  def resolve_local_stream(song, transcode:)
    path =
      if transcode
        new_transcoded_stream_path(song_id: song.id)
      else
        new_stream_path(song_id: song.id)
      end

    {
      stream_source: STREAM_SOURCE_LOCAL,
      resolved_stream_path: path,
      available: true
    }
  end

  def resolve_remote_stream(song)
    unless remote_connection_resolvable?(song)
      return {
        stream_source: STREAM_SOURCE_REMOTE,
        resolved_stream_path: "",
        available: false
      }
    end

    {
      stream_source: STREAM_SOURCE_REMOTE,
      resolved_stream_path: "#{REMOTE_STREAM_PATH_PREFIX}/#{song.id}",
      available: true
    }
  end

  # A remote streaming endpoint is reachable only when the owning library has an
  # active Library_Connection. A missing connection, or one that is revoked or
  # unavailable, cannot be resolved to an endpoint (Req 8.11). This delegates to
  # the shared RemoteAvailability predicate so path resolution and
  # Source_Preference selection can never disagree about reachability (Req 11.3).
  def remote_connection_resolvable?(record)
    RemoteAvailability.available?(record)
  end

  def resolve_local_asset(record, variant:)
    return absent_asset(ASSET_SOURCE_LOCAL) unless record.has_cover_image?

    {
      asset_source: ASSET_SOURCE_LOCAL,
      resolved_asset_path: local_asset_path(record, variant),
      available: true,
      present: true
    }
  end

  def resolve_remote_asset(record, variant:)
    unless remote_connection_resolvable?(record)
      return {
        asset_source: ASSET_SOURCE_REMOTE,
        resolved_asset_path: "",
        available: false,
        present: record.has_cover_image?
      }
    end

    return absent_asset(ASSET_SOURCE_REMOTE) unless record.has_cover_image?

    {
      asset_source: ASSET_SOURCE_REMOTE,
      resolved_asset_path: remote_asset_path(record, variant),
      available: true,
      present: true
    }
  end

  # No cover image is available from the record's source: the path is empty and
  # the cover image is indicated absent. The source is still considered resolved
  # (`available: true`), which distinguishes an absent asset (Req 9.7) from a
  # remote asset whose connection could not be resolved (Req 9.8).
  def absent_asset(source)
    {
      asset_source: source,
      resolved_asset_path: "",
      available: true,
      present: false
    }
  end

  # The current-server cover-image path. The app serves ActiveStorage through
  # the proxy route (`config.active_storage.resolve_model_to_route =
  # :rails_storage_proxy`), so this is the same same-origin path the existing
  # views and JSON builders produce via `cover_image_url_for` (Req 9.3, 9.5).
  def local_asset_path(record, variant)
    rails_storage_proxy_path(record.cover_image.variant(variant), only_path: true)
  end

  # The same-origin proxy path for a Remote_Library's cover image, mirroring the
  # remote stream proxy path. The requested variant is forwarded to the endpoint
  # only when a caller explicitly asked for one (Req 9.4).
  def remote_asset_path(record, variant)
    path = "#{REMOTE_ASSET_PATH_PREFIX}/#{asset_record_type(record)}/#{record.id}"
    variant.present? ? "#{path}?variant=#{normalize_variant(variant)}" : path
  end

  # "albums" for an Album, "artists" for an Artist, matching the federation asset
  # route's `record_type`.
  def asset_record_type(record)
    record.class.name.tableize
  end

  # Coerce the requested variant to a supported one, defaulting to :medium for a
  # missing or unrecognized value (mirrors `cover_image_url_for`).
  def normalize_variant(variant)
    return DEFAULT_ASSET_VARIANT if variant.nil?

    variant = variant.to_sym
    ASSET_VARIANTS.include?(variant) ? variant : DEFAULT_ASSET_VARIANT
  end
end
