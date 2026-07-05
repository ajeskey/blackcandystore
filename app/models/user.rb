# frozen_string_literal: true

class User < ApplicationRecord
  AVAILABLE_THEME_OPTIONS = %w[dark light auto].freeze
  DEFAULT_THEME = "auto"
  RECENTLY_PLAYED_LIMIT = 10

  include ScopedSettingConcern

  SOURCE_PREFERENCE_OPTIONS = %w[prefer_own_server prefer_highest_quality].freeze
  DEFAULT_SOURCE_PREFERENCE = "prefer_own_server"

  PLAYBACK_MODE_OPTIONS = %w[client_cast server_playback].freeze
  DEFAULT_PLAYBACK_MODE = "client_cast"

  has_secure_password
  has_setting :theme, default: DEFAULT_THEME
  # Which copy of a duplicated Song this user streams from. Defaults to
  # prefer_own_server when unset (Req 11.1, 11.2).
  has_setting :source_preference, default: DEFAULT_SOURCE_PREFERENCE
  # Whether this user's client casts audio directly (`client_cast`) or the
  # Server plays audio to the Output_Device (`server_playback`). Defaults to
  # client_cast when unset (Req 16.1, 16.2, 16.3).
  has_setting :playback_mode, default: DEFAULT_PLAYBACK_MODE
  serialize :recently_played_album_ids, type: Array, coder: YAML

  before_update :remove_deprecated_password_salt, if: :will_save_change_to_password_digest?
  after_update :broadcast_theme_change, if: :saved_change_to_theme?
  after_create :create_buildin_playlists

  normalizes :email, with: ->(email) { email.strip.downcase }

  validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }, uniqueness: { case_sensitive: false }
  validates :password, allow_nil: true, length: { minimum: 6 }
  validates :theme, inclusion: { in: AVAILABLE_THEME_OPTIONS }, allow_nil: true
  # A submitted Source_Preference value is persisted and applied only when it is
  # one of the supported options; any other value is rejected as a validation
  # error and the existing value is left unchanged (Req 11.10). Mirrors the
  # theme option validation above.
  validates :source_preference, inclusion: { in: SOURCE_PREFERENCE_OPTIONS }, allow_nil: true
  # A submitted Playback_Mode value is recorded and applied only when it is one
  # of the supported options; any other value is rejected as a validation error
  # and the existing mode is left unchanged (Req 16.4). Mirrors the
  # source_preference validation above.
  validates :playback_mode, inclusion: { in: PLAYBACK_MODE_OPTIONS }, allow_nil: true

  has_many :playlists, -> { where(type: nil) }, inverse_of: :user, dependent: :destroy
  has_many :sessions, dependent: :destroy

  # Libraries this user owns (server owner). Used to compute the set of
  # accessible libraries and the default Active_Library selection.
  has_many :owned_libraries, class_name: "Library", foreign_key: :owner_id, inverse_of: :owner, dependent: :nullify

  # The persisted Active_Library selection. Stored as a real column so it
  # survives sessions (Req 3.1). Optional because a user may not have selected
  # one yet, in which case the default-selection logic applies (Req 3.5).
  belongs_to :active_library, class_name: "Library", optional: true

  has_one :current_playlist, dependent: :destroy
  has_one :favorite_playlist, dependent: :destroy

  # ensure user always have current playlist
  def current_playlist
    super || create_current_playlist
  end

  # ensure user always have favorite playlist
  def favorite_playlist
    super || create_favorite_playlist
  end

  def favorited?(song)
    favorite_playlist.songs.exists? song.id
  end

  # User created playlists with favorite playlist
  def playlists_with_favorite
    playlists.unscope(where: :type).where("playlists.type IS NULL OR playlists.type = ?", "FavoritePlaylist")
  end

  def all_playlists
    playlists.unscope(where: :type)
  end

  # Select this user's Playback_Mode and enforce the mode-exclusivity invariant
  # so the other mode's session no longer manages an activity (Req 16, 18;
  # Property 21). An unsupported value is rejected leaving the mode unchanged
  # (Req 16.4). Returns the session that now manages the activity.
  def select_playback_mode(mode)
    PlaybackMode.select(self, mode)
  end

  # The session managing this user's playback activity under the current
  # Playback_Mode: a Cast_Session under `client_cast`, a Playback_Session under
  # `server_playback` (Req 18.2, 18.3).
  def playback_activity_session
    PlaybackMode.for(self)
  end

  def recently_played_albums
    album_ids = recently_played_album_ids
    order_clause = album_ids.map { |id| "id=#{id} desc" }.join(",")

    Album.includes(:artist).where(id: album_ids).order(Arel.sql(order_clause))
  end

  def add_album_to_recently_played(album)
    album_ids = recently_played_album_ids.unshift(album.id).uniq.take(RECENTLY_PLAYED_LIMIT)
    update_column(:recently_played_album_ids, album_ids)
  end

  # The libraries this user is authorized to browse. For now this is the set of
  # local libraries the user owns. Remote libraries reached through active
  # Library_Connections join this set in Phase 2, and the LibraryAccess concern
  # (task 5.2) will centralize the authorization rules. Kept as a small,
  # forward-compatible helper so callers depend on the concept, not the query.
  def accessible_libraries
    Library.local.where(owner_id: id)
  end

  # The Remote_Libraries this user can currently reach through an active
  # Library_Connection. Guarded so it is a no-op until the Phase 2
  # `library_connections` table exists (Req 3.4). Kept on the model so both the
  # LibraryAccess controller concern and AuthorizedContent derive the remote set
  # from a single place and never diverge.
  def active_remote_libraries
    return Library.none unless defined?(LibraryConnection) && LibraryConnection.table_exists?

    active_connection_ids = LibraryConnection.where(user_id: id, status: "active").select(:id)
    Library.remote.where(library_connection_id: active_connection_ids)
  end

  # The ids of every library this user is authorized to browse: the owned
  # Local_Libraries plus the Remote_Libraries reached through an active
  # Library_Connection (Req 3.4). This is the single derivation shared by the
  # LibraryAccess controller concern (browsing/streaming) and by
  # AuthorizedContent (DAAP/RSP serving) so the authorization model stays
  # consistent across all callers.
  def authorized_library_ids
    accessible_libraries.ids + active_remote_libraries.ids
  end

  # The Active_Library the user currently browses. Returns the persisted
  # selection when present (Req 3.1). Otherwise, when the user can access
  # exactly one library, that library becomes the Active_Library by default and
  # the selection is persisted so it survives future sessions (Req 3.5).
  def active_library
    super || default_active_library
  end

  private

  def default_active_library
    libraries = accessible_libraries
    return unless libraries.count == 1

    library = libraries.first
    update_column(:active_library_id, library.id) if persisted?
    library
  end

  def remove_deprecated_password_salt
    self.deprecated_password_salt = nil if deprecated_password_salt.present?
  end

  def create_buildin_playlists
    create_current_playlist
    create_favorite_playlist
  end

  def broadcast_theme_change
    broadcast_replace_to self, :theme, target: "turbo-theme", partial: "shared/theme_meta", locals: { theme: theme }
  end
end
