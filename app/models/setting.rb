# frozen_string_literal: true

class Setting < ApplicationRecord
  include GlobalSettingConcern

  AVAILABLE_BITRATE_OPTIONS = [ 128, 192, 320 ].freeze

  has_setting :media_path, default: proc { BlackCandy.config.media_path }
  has_setting :discogs_token
  has_setting :transcode_bitrate, type: :integer, default: 128
  has_setting :allow_transcode_lossless, type: :boolean, default: false
  has_setting :enable_media_listener, type: :boolean, default: false
  has_setting :enable_parallel_media_sync, type: :boolean, default: false
  has_setting :enable_daap, type: :boolean, default: false
  has_setting :enable_rsp, type: :boolean, default: false

  # API key for setlist.fm live-music enrichment (setlist validation, venue,
  # event date). Free for non-commercial use; enrichment is skipped when unset.
  # Open Library (audiobook enrichment) needs no key, so it has no setting.
  has_setting :setlistfm_api_key

  # The Server's public base URL (hostname/IP + scheme + optional port) encoded
  # into every Invite_Code so a redeeming Server knows how to reach this one
  # (Req 4.3). Configurable at runtime here; falls back to the SERVER_BASE_URL
  # env config when unset, so existing env-based deployments keep working.
  has_setting :server_base_url, default: proc { BlackCandy.config.server_base_url }

  # Admin/global cap on the number of Radio_Station and Co_Listen_Session
  # broadcasts that may run concurrently. Enforced in Rails at start/activate
  # against the count of currently live broadcasts (Req 10.5, 10.6).
  has_setting :max_concurrent_streams, type: :integer

  validates :transcode_bitrate, inclusion: { in: AVAILABLE_BITRATE_OPTIONS }, allow_nil: true
  validate :media_path_exist
  validate :parallel_media_sync_database
  validate :server_base_url_valid

  after_update :toggle_media_listener, if: :saved_change_to_enable_media_listener?
  after_update_commit :sync_media, if: :saved_change_to_media_path?

  private

  def media_path_exist
    return if media_path.nil?

    errors.add(:media_path, :blank) and return if media_path.blank?

    path = File.expand_path(media_path)

    errors.add(:media_path, :not_exist) unless File.exist?(path)
    errors.add(:media_path, :unreadable) unless File.readable?(path)
  end

  # A configured base URL must be an absolute http(s) URL with a host, so the
  # value encoded into Invite_Codes is actually reachable. Blank is allowed and
  # falls back to the env default.
  def server_base_url_valid
    value = server_base_url
    return if value.blank?

    uri = URI.parse(value)
    valid = uri.is_a?(URI::HTTP) && uri.host.present?
    errors.add(:server_base_url, :invalid) unless valid
  rescue URI::InvalidURIError
    errors.add(:server_base_url, :invalid)
  end

  def parallel_media_sync_database
    return unless enable_parallel_media_sync?

    if BlackCandy.config.db_adapter == "sqlite"
      errors.add(:enable_parallel_media_sync, :not_supported_with_sqlite)
    end
  end

  def sync_media
    MediaSyncAllJob.perform_later
  end

  def toggle_media_listener
    if enable_media_listener?
      MediaListener.start
    else
      MediaListener.stop
    end
  end
end
