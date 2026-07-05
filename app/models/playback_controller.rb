# frozen_string_literal: true

# PlaybackController is the Server component that manages Playback_Sessions and
# applies the play, resume, pause, stop, volume, and device-selection control
# operations received through the API (Req 14).
#
# This class implements ONLY the server-side session STATE MACHINE and its
# control semantics. It is deliberately pure and deterministic: given a
# Playback_Session and a control operation it decides the next state and the
# active Output_Device set with no side effects beyond persisting the session.
# The actual audio dispatch to AirPlay/Chromecast devices (decoding a Song and
# sending synchronized audio over the wire) lives behind an out-of-process
# playback sidecar and is exercised by the integration tests (task 24.3), NOT
# here. Keeping the state logic separate is what lets Property 20 (task 24.2)
# property-test every transition without the sidecar.
#
# State invariant (Req 14.15): a Playback_Session is ALWAYS in exactly one of
# `stopped`, `playing`, or `paused` — the same set enforced by
# PlaybackSession::STATES. Every operation below either leaves the state in that
# set or is rejected leaving the prior state unchanged.
#
# Reachability is injectable (`reachable:`) so the state machine can be tested
# without Device_Discovery or the sidecar. The default resolver treats an
# Output_Device as reachable when a persisted row for it has a `reachable_at`
# timestamp recorded by Device_Discovery (task 23.1); tests pass a simple
# callable or set instead.
class PlaybackController
  # The outcome of a control operation. `ok?` reports whether the operation was
  # applied; a rejected operation carries an `error` code and leaves the
  # session's state and active devices unchanged. `reason` carries an
  # additional indication for operations that succeed with a notable side
  # effect (e.g. playback stopping because no Output_Device remained — Req
  # 14.12). `session` is always the (possibly unchanged) Playback_Session.
  Result = Struct.new(:ok, :error, :reason, :session, keyword_init: true) do
    def ok?
      ok
    end

    def rejected?
      !ok
    end
  end

  STATE_STOPPED = "stopped"
  STATE_PLAYING = "playing"
  STATE_PAUSED = "paused"

  # Inclusive supported volume range for a volume control operation (Req 14.6).
  VOLUME_RANGE = (0..100)

  # Reason returned when playback stops because the last active Output_Device
  # became unavailable during `playing` (Req 14.12).
  REASON_NO_DEVICE_AVAILABLE = "no_output_device_available"

  # Purpose namespace and TTL for the signed, song-scoped stream token handed to
  # the playback sidecar so it can fetch a Song's audio from this Server without
  # a login session (verified by SidecarStreamAccess). A short TTL bounds the
  # window in which a leaked token is usable; a fresh token is minted on every
  # dispatch.
  SIDECAR_STREAM_PURPOSE = :sidecar_stream
  SIDECAR_STREAM_TOKEN_TTL = 6.hours

  # Default reachability resolver (Req 14.13). An Output_Device is reachable
  # when a persisted row exists for its id and Device_Discovery has stamped a
  # `reachable_at` on it. This is intentionally injectable so the state machine
  # is testable without discovery or the sidecar.
  DEFAULT_REACHABLE = ->(device_id) {
    OutputDevice.where(id: device_id).where.not(reachable_at: nil).exists?
  }

  # Find or create the Playback_Session for a User (Req 14.1, 14.17, 14.18).
  #
  # @param user [User]
  # @param reachable [#call] a callable `device_id -> Boolean`
  # @return [PlaybackController]
  def self.for_user(user, reachable: DEFAULT_REACHABLE)
    new(PlaybackSession.find_or_create_by!(user: user), reachable: reachable)
  end

  # @param session [PlaybackSession] the session this controller operates on
  # @param reachable [#call] a callable `device_id -> Boolean` used to decide
  #   whether an Output_Device may be selected as an active target (Req 14.13).
  def initialize(session, reachable: DEFAULT_REACHABLE)
    @session = session
    @reachable = reachable
  end

  attr_reader :session

  # Select one or more Output_Devices as the session's active playback targets
  # (Req 14.1, 14.17, 14.18). Every requested device must currently be reachable
  # (Req 14.13); if ANY requested device is unreachable the whole selection is
  # rejected and the session's active Output_Devices are left unchanged
  # (Req 14.13). On success the active Output_Device set is replaced with the
  # requested devices. Selection does not change the playback state.
  #
  # @param device_ids [Array<Integer>] the Output_Device ids to make active
  # @return [Result]
  def select_devices(device_ids)
    ids = normalize_ids(device_ids)

    unreachable = ids.reject { |id| reachable?(id) }
    return failure(:device_unreachable) if unreachable.any?

    @session.active_output_device_ids = ids
    @session.save!
    success
  end

  # Start playing a Song (Req 14.3). Rejected with `no_output_device` when the
  # session has no active Output_Device, leaving the state unchanged (Req
  # 14.14). Rejected with `no_current_song` when no Song is given to play. On
  # success the current Song and position are recorded and the state becomes
  # `playing`. The audio dispatch itself is delegated to the sidecar (task
  # 24.3) and is out of scope here.
  #
  # @param song_id [Integer] the Song to play
  # @param position [Integer] the starting playback position (default 0)
  # @return [Result]
  def play(song_id:, position: 0)
    return failure(:no_output_device) unless active_devices?
    return failure(:no_current_song) if song_id.blank?

    @session.assign_attributes(
      current_song_id: song_id,
      position: position.to_i,
      state: STATE_PLAYING
    )
    @session.save!
    success
  end

  # Resume a paused (or already-playing) session (Req 14.3, 14.16). Rejected
  # with `no_output_device` when the session has no active Output_Device,
  # leaving the state unchanged (Req 14.14). Rejected with `no_current_song`
  # when there is no current Song to resume. On success the state becomes
  # `playing` while the current Song and playback position retained at pause are
  # kept unchanged (Req 14.16) — this is exactly the resume-after-pause
  # transition property.
  #
  # @return [Result]
  def resume
    return failure(:no_output_device) unless active_devices?
    return failure(:no_current_song) if @session.current_song_id.blank?

    # Retain current_song_id and position; only the state transitions (Req 14.16).
    @session.state = STATE_PLAYING
    @session.save!
    success
  end

  # Pause a playing session (Req 14.4). Stops sending audio (sidecar concern)
  # while retaining the current Song and playback position, and sets the state
  # to `paused`. Pausing a session that is not `playing` is a no-op that leaves
  # the state unchanged, preserving the state invariant (Req 14.15).
  #
  # @return [Result]
  def pause
    return success unless @session.state == STATE_PLAYING

    # Retain current_song_id and position (Req 14.4); only the state changes.
    @session.state = STATE_PAUSED
    @session.save!
    success
  end

  # Stop the session (Req 14.5). Stops sending audio (sidecar concern), clears
  # the current playback position, and sets the state to `stopped`. The current
  # Song association is retained; only the position is cleared per Req 14.5.
  #
  # @return [Result]
  def stop
    @session.assign_attributes(state: STATE_STOPPED, position: 0)
    @session.save!
    success
  end

  # Set the volume for a specific active Output_Device or for the whole active
  # multi-room group (Req 14.6). The requested level must fall within the
  # supported volume range; an out-of-range level is rejected and the session
  # is left unchanged. Volume does not affect the playback state. The actual
  # volume change is applied by the sidecar; here we validate and accept the
  # control operation.
  #
  # @param level [Integer] the requested volume level within VOLUME_RANGE
  # @param device_id [Integer, nil] a specific active device, or nil for the
  #   whole active group
  # @return [Result]
  def set_volume(level, device_id: nil)
    return failure(:invalid_volume) unless level.is_a?(Numeric) && VOLUME_RANGE.cover?(level)

    # Volume targets a currently active device (or the whole active group); a
    # request for a device that is not active is rejected without side effects.
    if device_id.present? && !@session.active_output_device_ids.include?(device_id.to_i)
      return failure(:device_not_active)
    end

    success
  end

  # Dispatch the current Song's audio to the session's active Output_Devices via
  # the out-of-process playback sidecar (Req 14.2, 14.7, 14.8, 14.9, 14.10).
  #
  # This is the thin audio-dispatch seam deferred by `play`/`resume`: the state
  # machine decides *that* audio should be playing; this method decides *what*
  # stream to decode and hands it to the sidecar, which owns the actual
  # AirPlay/Chromecast framing. It never drives protocols itself.
  #
  # Behaviour:
  # - Rejected with `no_output_device` when the session has no active device and
  #   `no_current_song` when there is no current Song — nothing is dispatched.
  # - The current Song's Stream_Source is classified through Path_Resolver: a
  #   Local_Library Song decodes from the current Server (`local`, Req 14.9); a
  #   Remote_Library Song is retrieved through its Library_Connection via the
  #   same-origin remote proxy path (`remote`, Req 14.10). A remote Song whose
  #   connection cannot be resolved is unavailable and dispatch is rejected with
  #   `song_unavailable` without contacting the sidecar.
  # - Every active device receives the audio; more than one AirPlay_Device forms
  #   a synchronized multi-room group handled by the sidecar (Req 14.2).
  # - A password-protected Output_Device requires a device password (Req 14.7):
  #   if any protected active device has no supplied credential the operation is
  #   rejected with `device_authentication_required` and no audio is sent
  #   (Req 14.8). If the sidecar reports the presented credential is incorrect it
  #   is rejected with `device_authentication_error` (Req 14.8).
  # - A sidecar that is unreachable or errors yields `sidecar_unavailable`.
  #
  # @param credentials [Hash{Integer=>String}] per-device passwords keyed by
  #   Output_Device id, for password-protected AirPlay_Devices (Req 14.7)
  # @param user [User, nil] the User whose Source_Preference resolves duplicated
  #   content (passed through to Path_Resolver)
  # @param client [PlaybackSidecar::Client] injectable sidecar client seam
  # @param resolver [PathResolver] injectable stream resolver seam
  # @return [Result]
  def dispatch_audio(credentials: {}, user: nil, client: PlaybackSidecar.client, resolver: PathResolver.new)
    return failure(:no_output_device) unless active_devices?
    return failure(:no_current_song) if @session.current_song_id.blank?

    song = Song.find_by(id: @session.current_song_id)
    return failure(:no_current_song) if song.nil?

    devices = OutputDevice.where(id: @session.active_output_device_ids).to_a

    creds = normalize_credentials(credentials)
    protected_without_credential = devices.select do |device|
      device.requires_password && creds[device.id].blank?
    end
    # Missing credential for a password-protected device: reject before sending
    # any audio to it (Req 14.7, 14.8).
    return failure(:device_authentication_required) if protected_without_credential.any?

    stream = resolver.resolve_stream(song, user: user)
    # A remote Song whose Library_Connection cannot be resolved has no reachable
    # audio to decode (Req 14.10); do not contact the sidecar.
    return failure(:song_unavailable) unless stream[:available]

    begin
      client.play(
        device_ids: devices.map(&:id),
        devices: devices.map { |device| device_descriptor(device) },
        stream_source: stream[:stream_source],
        stream_url: stream[:resolved_stream_path],
        stream_token: sidecar_stream_token(song),
        credentials: creds
      )
    rescue PlaybackSidecar::AuthenticationError
      # The sidecar rejected a presented device credential as incorrect (Req 14.8).
      return failure(:device_authentication_error)
    rescue PlaybackSidecar::Unavailable
      return failure(:sidecar_unavailable)
    end

    success
  end

  # Handle an active Output_Device becoming unavailable or disconnecting
  # (Req 14.11, 14.12). The device is removed from the session's active
  # Output_Device set. If the session was `playing` and other active devices
  # remain, playback continues on them (Req 14.11). If the LAST active device
  # was removed while `playing`, the state becomes `stopped` and the result
  # carries a reason indicating playback stopped because no Output_Device
  # remained available (Req 14.12). Losing a device while not `playing` simply
  # updates the active set.
  #
  # @param device_id [Integer] the Output_Device that became unavailable
  # @return [Result]
  def device_unavailable(device_id)
    id = device_id.to_i
    remaining = @session.active_output_device_ids - [ id ]
    return success unless remaining != @session.active_output_device_ids

    was_playing = @session.state == STATE_PLAYING
    @session.active_output_device_ids = remaining

    if was_playing && remaining.empty?
      # The last active Output_Device was lost during playback (Req 14.12).
      @session.state = STATE_STOPPED
      @session.save!
      return success(reason: REASON_NO_DEVICE_AVAILABLE)
    end

    # Remaining devices keep playing, or the session was not playing (Req 14.11).
    @session.save!
    success
  end

  private

  def active_devices?
    @session.active_output_device_ids.any?
  end

  # A device descriptor the sidecar can act on. The Rails `id` keys credentials;
  # the protocol-level `identifier` is what the sidecar uses to reach the real
  # AirPlay/Chromecast target (Req 13.6).
  def device_descriptor(device)
    {
      id: device.id,
      identifier: device.identifier,
      protocol: device.protocol,
      requires_password: device.requires_password
    }
  end

  # A short-lived, song-scoped signed token authorizing the sidecar to fetch
  # this Song's audio stream from the current Server without a login session.
  def sidecar_stream_token(song)
    song.signed_id(purpose: PlaybackController::SIDECAR_STREAM_PURPOSE, expires_in: PlaybackController::SIDECAR_STREAM_TOKEN_TTL)
  end

  def reachable?(device_id)
    @reachable.call(device_id)
  end

  def normalize_ids(device_ids)
    Array(device_ids).map(&:to_i).uniq
  end

  # Coerce a per-device credentials hash to integer-keyed device ids so lookups
  # against Output_Device ids are consistent regardless of how the caller keyed
  # them (string vs integer).
  def normalize_credentials(credentials)
    return {} unless credentials.respond_to?(:each_pair)

    credentials.each_with_object({}) do |(device_id, password), acc|
      acc[device_id.to_i] = password
    end
  end

  def success(reason: nil)
    Result.new(ok: true, error: nil, reason: reason, session: @session)
  end

  def failure(error)
    Result.new(ok: false, error: error, reason: nil, session: @session)
  end
end
