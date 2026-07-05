# frozen_string_literal: true

# PlaybackMode is the Server component that selects a User's Playback_Mode and
# enforces the mode-exclusivity invariant (Req 16, 18; design Property 21).
#
# A User's active playback activity is classified as exactly one Playback_Mode,
# read from User#playback_mode (`client_cast` or `server_playback`, validated by
# the User model — Req 16.1, 16.4). That classification determines both which
# session manages the activity and which end is the audio source:
#
#   * `client_cast`    -> managed by a Cast_Session; the Cast_Client (the
#                         Web_Player/App_Player) is the audio source and the
#                         Server is NOT (Req 16.6, 18.2, 18.4).
#   * `server_playback` -> managed by a Playback_Session; the Server is the
#                         audio source and neither player is (Req 16.7, 18.3,
#                         18.5).
#
# The exclusivity invariant (Property 21, Req 18.1) says no single activity is
# ever managed by BOTH a Cast_Session and a Playback_Session at the same time.
# Because each session is one-per-user, this reduces to: at most one of a
# User's two sessions may be active (non-`stopped`) at a time. `select` sets the
# mode and then tears down the other mode's session so only the selected mode's
# session can manage the activity. Every concurrent `client_cast` activity is
# therefore managed by a Cast_Session (Req 18.6), never left unmanaged.
#
# This is a pure coordination layer over the existing CastSession model and
# PlaybackController/PlaybackSession state machines — it composes them rather
# than reimplementing any transition logic, so it stays deterministic and
# unit-/property-testable (Property 21 is exercised by task 26.2).
module PlaybackMode
  MODE_CLIENT_CAST = "client_cast"
  MODE_SERVER_PLAYBACK = "server_playback"

  # The audio source under each mode (Req 16.6, 16.7, 18.4, 18.5).
  AUDIO_SOURCE_CLIENT = "client"
  AUDIO_SOURCE_SERVER = "server"

  # The session kind that manages an activity under each mode (Req 18.2, 18.3).
  MANAGER_CAST_SESSION = :cast_session
  MANAGER_PLAYBACK_SESSION = :playback_session

  # The session that manages the User's active playback activity under their
  # current Playback_Mode, creating it on demand so a `client_cast` activity is
  # always managed (Req 18.6). Under `client_cast` this is the User's
  # Cast_Session; under `server_playback` it is the User's Playback_Session.
  #
  # @param user [User]
  # @return [CastSession, PlaybackSession]
  def self.session_for(user)
    case user.playback_mode
    when MODE_CLIENT_CAST
      CastSession.find_or_create_by!(user: user)
    when MODE_SERVER_PLAYBACK
      PlaybackSession.find_or_create_by!(user: user)
    end
  end

  # Keyword-named convenience alias matching the documented API
  # (`PlaybackMode.for(user)`); delegates to #session_for.
  def self.for(user)
    session_for(user)
  end

  # The class of session that manages this User's activity under the current
  # mode — MANAGER_CAST_SESSION or MANAGER_PLAYBACK_SESSION.
  #
  # @param user [User]
  # @return [Symbol, nil]
  def self.manager(user)
    case user.playback_mode
    when MODE_CLIENT_CAST then MANAGER_CAST_SESSION
    when MODE_SERVER_PLAYBACK then MANAGER_PLAYBACK_SESSION
    end
  end

  # Which end is the audio source under the User's current mode — the client for
  # `client_cast`, the Server for `server_playback` (Req 16.6, 16.7).
  #
  # @param user [User]
  # @return [String, nil]
  def self.audio_source(user)
    case user.playback_mode
    when MODE_CLIENT_CAST then AUDIO_SOURCE_CLIENT
    when MODE_SERVER_PLAYBACK then AUDIO_SOURCE_SERVER
    end
  end

  # Select a Playback_Mode for the User and enforce exclusivity.
  #
  # The mode is recorded through the User model, whose inclusion validation
  # rejects any value other than `client_cast`/`server_playback` by raising
  # ActiveRecord::RecordInvalid and leaving the existing mode unchanged
  # (Req 16.4). On a successful change the other mode's session is deactivated
  # so no activity is managed by both a Cast_Session and a Playback_Session
  # (Req 18.1; Property 21). Returns the session that now manages the activity.
  #
  # @param user [User]
  # @param mode [String] the requested Playback_Mode
  # @return [CastSession, PlaybackSession]
  def self.select(user, mode)
    user.update!(playback_mode: mode)
    enforce_exclusivity!(user)
    session_for(user)
  end

  # Tear down the session of the mode that is NOT currently selected so only the
  # selected mode's session manages the activity (Req 18.1, 18.2, 18.3;
  # Property 21 "no activity managed by both"). Deactivation reuses the existing
  # stop semantics: a stopped session manages no activity.
  #
  # @param user [User]
  # @return [void]
  def self.enforce_exclusivity!(user)
    case user.playback_mode
    when MODE_CLIENT_CAST
      deactivate_server_playback(user)
    when MODE_SERVER_PLAYBACK
      deactivate_client_cast(user)
    end
    nil
  end

  # True when the User's playback obeys the exclusivity invariant: the session
  # of the non-selected mode either does not exist or is idle (`stopped`), so at
  # most one session actively manages the activity (Property 21, Req 18.1).
  #
  # @param user [User]
  # @return [Boolean]
  def self.exclusive?(user)
    other = other_mode_session(user)
    other.nil? || !other.active?
  end

  # The persisted session of the mode NOT currently selected, or nil when none
  # exists. Under `client_cast` this is the Playback_Session; under
  # `server_playback` it is the Cast_Session.
  #
  # @param user [User]
  # @return [CastSession, PlaybackSession, nil]
  def self.other_mode_session(user)
    case user.playback_mode
    when MODE_CLIENT_CAST then PlaybackSession.find_by(user: user)
    when MODE_SERVER_PLAYBACK then CastSession.find_by(user: user)
    end
  end

  # Stop the User's Playback_Session (server_playback) if one exists, so the
  # Server is no longer the audio source for any activity. Delegates to the
  # PlaybackController state machine so the stop transition stays authoritative.
  def self.deactivate_server_playback(user)
    session = PlaybackSession.find_by(user: user)
    return if session.nil?

    PlaybackController.new(session).stop
  end
  private_class_method :deactivate_server_playback

  # Stop the User's Cast_Session (client_cast) if one exists, so the client is
  # no longer casting for any activity. Reuses CastSession#stop and persists it.
  def self.deactivate_client_cast(user)
    session = CastSession.find_by(user: user)
    return if session.nil?

    session.stop
    session.save!
  end
  private_class_method :deactivate_client_cast
end
