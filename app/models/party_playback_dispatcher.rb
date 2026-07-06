# frozen_string_literal: true

# PartyPlaybackDispatcher is the Party Mode counterpart to PlaybackController's
# `dispatch_audio`: it plays a Party_Session's Shared_Playlist to the Host's
# selected Output_Devices through the out-of-process Playback_Sidecar
# (Req 6.1, 6.3). The Shared_Playlist is played in its current order and loops
# back to the beginning once its last entry has played (Req 6.7), and when a
# selected device becomes unavailable playback continues on the remaining
# devices — stopping for the session once none remain (Req 6.4).
#
# Like PlaybackController and ProgramSequencer, the decision that matters for
# correctness is kept PURE and side-effect-free: `decide_device_loss` computes
# the remaining device set and whether playback continues or stops given the
# current selection and the lost device, with no I/O. That is the seam
# Property 24 (device-loss continuation) property-tests, so it must never touch
# the database, the sequencer, or the sidecar. The instance methods wire that
# decision (and ProgramSequencer's ordering) to the persisted selection and the
# Playback_Sidecar; the actual AirPlay/Chromecast framing lives entirely in the
# sidecar and is exercised by integration tests (task 11.3), never here.
#
# Song ordering is delegated to ProgramSequencer in `MODE_PLAYLIST`, which
# advances through the Shared_Playlist entries in order and wraps at the end
# (the loop-at-end behaviour of Req 6.7). The Playback_Sidecar client and the
# PathResolver are both injectable so tests can drive dispatch with fakes.
class PartyPlaybackDispatcher
  # The outcome of a dispatch/transport operation. `ok?` reports whether audio
  # was dispatched (or the operation applied); a rejected operation carries an
  # `error` code and leaves the selection unchanged. `reason` carries a notable
  # side effect — e.g. playback stopping because no selected device remained
  # (Req 6.4). `song_id` and `device_ids` report what was dispatched. Mirrors
  # PlaybackController::Result.
  Result = Struct.new(:ok, :error, :reason, :song_id, :device_ids, keyword_init: true) do
    def ok?
      ok
    end

    def rejected?
      !ok
    end
  end

  # The pure decision of what happens to a Party_Session's playback when one of
  # its selected Output_Devices is lost (Req 6.4; Property 24). `remaining_device_ids`
  # is the selection minus the lost device; `action` is `:continue` when devices
  # remain (playback keeps going on them) or `:stop` when the last one was lost
  # (playback stops for the session).
  DeviceLossDecision = Struct.new(:remaining_device_ids, :action, keyword_init: true) do
    def continue?
      action == ACTION_CONTINUE
    end

    def stop?
      action == ACTION_STOP
    end
  end

  # Device-loss actions (Req 6.4).
  ACTION_CONTINUE = :continue
  ACTION_STOP = :stop

  # Reason returned when playback stops because the last selected Output_Device
  # became unavailable (Req 6.4). Mirrors PlaybackController's equivalent.
  REASON_NO_DEVICE_AVAILABLE = "no_output_device_available"

  # Convenience constructor mirroring `PlaybackController.for_user`.
  #
  # @param session [PartySession] the Party_Session to dispatch for
  # @param client [PlaybackSidecar::Client] injectable sidecar client seam
  # @param resolver [PathResolver] injectable stream resolver seam
  # @return [PartyPlaybackDispatcher]
  def self.for_session(session, client: PlaybackSidecar.client, resolver: PathResolver.new)
    new(session, client: client, resolver: resolver)
  end

  # @param session [PartySession] the Party_Session to dispatch for
  # @param client [PlaybackSidecar::Client] injectable sidecar client seam
  # @param resolver [PathResolver] injectable stream resolver seam
  def initialize(session, client: PlaybackSidecar.client, resolver: PathResolver.new)
    @session = session
    @client = client
    @resolver = resolver
  end

  attr_reader :session

  # The pure device-loss continuation decision (Req 6.4; Property 24). Given the
  # currently selected device ids and the device that became unavailable, it
  # returns the remaining selection and whether playback continues on them or
  # stops because none remain. No side effects: it neither persists the
  # selection nor contacts the sidecar, so a `:stop` decision leaves the caller
  # to apply the stop.
  #
  # @param active_device_ids [Array<Integer>] the currently selected device ids
  # @param lost_device_id [Integer] the Output_Device that became unavailable
  # @return [DeviceLossDecision]
  def self.decide_device_loss(active_device_ids:, lost_device_id:)
    remaining = normalize_ids(active_device_ids) - [ lost_device_id.to_i ]
    action = remaining.empty? ? ACTION_STOP : ACTION_CONTINUE
    DeviceLossDecision.new(remaining_device_ids: remaining, action: action)
  end

  # Coerce an enumerable of device ids (or Output_Device records) to a unique
  # array of integer ids, preserving order. Shared by the pure decision and the
  # instance methods so selection comparisons are type-consistent.
  def self.normalize_ids(device_ids)
    Array(device_ids).map { |device| device.respond_to?(:id) ? device.id : device }.map(&:to_i).uniq
  end

  # Replace the Host's selected Output_Devices and dispatch the Shared_Playlist's
  # current Song to them (Req 6.1). Selecting an empty set clears the selection
  # and stops playback for the session (there is nothing to play to). Otherwise
  # the selection is persisted and the current Song is dispatched from the top of
  # the Shared_Playlist (no history) via {#dispatch}.
  #
  # @param device_ids [Array<Integer>] the Output_Device ids to play to
  # @param user [User, nil] the User whose Source_Preference resolves the stream
  # @return [Result]
  def select_devices(device_ids, user: nil)
    ids = self.class.normalize_ids(device_ids)
    persist_selection(ids)

    return stop if ids.empty?

    dispatch(user: user)
  end

  # Dispatch the Shared_Playlist's current Song to the selected Output_Devices
  # through the Playback_Sidecar (Req 6.1, 6.3). The current Song is chosen by
  # ProgramSequencer in `MODE_PLAYLIST` over the Shared_Playlist's ordered
  # entries, so playback follows the playlist order and loops at the end
  # (Req 6.7). Rejected with:
  #   * `no_output_device` when no device is selected — nothing is dispatched;
  #   * `no_current_song` when the Shared_Playlist has no playable Song at the
  #     current position (empty playlist / continuity) or the Song is missing;
  #   * `song_unavailable` when a remote Song's connection cannot be resolved;
  #   * `sidecar_unavailable` when the sidecar cannot be reached.
  # On success every selected device receives the audio and the dispatched
  # `song_id`/`device_ids` are reported.
  #
  # @param history [Array<Integer>] recently played song ids, oldest first, used
  #   by ProgramSequencer to advance through and loop the playlist (Req 6.7)
  # @param user [User, nil] the User whose Source_Preference resolves the stream
  # @return [Result]
  def dispatch(history: [], user: nil)
    device_ids = selected_device_ids
    return failure(:no_output_device) if device_ids.empty?

    song_id = current_song_id(history: history)
    return failure(:no_current_song) if song_id.nil?

    song = Song.find_by(id: song_id)
    return failure(:no_current_song) if song.nil?

    devices = OutputDevice.where(id: device_ids).to_a
    return failure(:no_output_device) if devices.empty?

    stream = @resolver.resolve_stream(song, user: user)
    # A remote Song whose Library_Connection cannot be resolved has no reachable
    # audio to decode (Req 6.1); do not contact the sidecar.
    return failure(:song_unavailable) unless stream[:available]

    begin
      @client.play(
        device_ids: devices.map(&:id),
        devices: devices.map { |device| device_descriptor(device) },
        stream_source: stream[:stream_source],
        stream_url: stream[:resolved_stream_path],
        stream_token: sidecar_stream_token(song)
      )
    rescue PlaybackSidecar::Unavailable
      return failure(:sidecar_unavailable)
    end

    success(song_id: song_id, device_ids: devices.map(&:id))
  end

  # Handle a selected Output_Device becoming unavailable during a Party_Session
  # (Req 6.4). Applies the pure {.decide_device_loss} decision: the device is
  # removed from the selection, and if devices remain playback continues on them
  # (a fresh dispatch to the remaining set); if the last device was lost,
  # playback stops for the session and the result carries
  # {REASON_NO_DEVICE_AVAILABLE}.
  #
  # @param device_id [Integer] the Output_Device that became unavailable
  # @param history [Array<Integer>] recently played song ids for continuation
  # @param user [User, nil] the User whose Source_Preference resolves the stream
  # @return [Result]
  def device_unavailable(device_id, history: [], user: nil)
    decision = self.class.decide_device_loss(
      active_device_ids: selected_device_ids,
      lost_device_id: device_id
    )

    persist_selection(decision.remaining_device_ids)

    if decision.stop?
      result = stop
      return success(reason: REASON_NO_DEVICE_AVAILABLE, device_ids: []) if result.ok?

      return result
    end

    # Devices remain: continue playback on them from the current position.
    dispatch(history: history, user: user)
  end

  # Stop playback for the Party_Session (Req 6.4). Because the Playback_Sidecar
  # only exposes a play command, stopping is expressed by clearing the selected
  # Output_Devices so no further audio is dispatched to them; this is the same
  # effect the state machine models when the last device is lost. Reports the
  # (now empty) selection.
  #
  # @return [Result]
  def stop
    persist_selection([])
    success(device_ids: [])
  end

  private

  # The current selection's device ids, freshly read so a prior mutation in this
  # instance is reflected.
  def selected_device_ids
    @session.output_device_ids.map(&:to_i)
  end

  # Replace the Party_Session's selected Output_Devices with `ids`. Uses the
  # through-association writer so the `party_output_devices` join rows match the
  # requested set exactly (idempotent for an unchanged set).
  def persist_selection(ids)
    @session.output_device_ids = self.class.normalize_ids(ids)
  end

  # The Song to play at the current position, chosen by ProgramSequencer over
  # the Shared_Playlist's ordered entries (Req 6.3) with loop-at-end (Req 6.7).
  # Returns nil when the playlist is empty or the sequencer yields Continuity_Audio.
  def current_song_id(history:)
    playlist = @session.shared_playlist
    ordered_ids = playlist ? playlist.ordered_song_ids : []

    selection = ProgramSequencer.next_selection(
      ordered_ids,
      history: history,
      mode: ProgramSequencer::MODE_PLAYLIST
    )

    selection.song? ? selection.song_id : nil
  end

  # A device descriptor the sidecar can act on, matching PlaybackController's
  # shape: the Rails `id` keys the device while `identifier`/`protocol` are what
  # the sidecar uses to reach the real AirPlay/Chromecast target.
  def device_descriptor(device)
    {
      id: device.id,
      identifier: device.identifier,
      protocol: device.protocol,
      requires_password: device.requires_password
    }
  end

  # A short-lived, song-scoped signed token authorizing the sidecar to fetch the
  # Song's audio from this Server without a login session. Reuses
  # PlaybackController's sidecar-stream purpose and TTL so a single
  # SidecarStreamAccess verifier covers both server-playback and party dispatch.
  def sidecar_stream_token(song)
    song.signed_id(
      purpose: PlaybackController::SIDECAR_STREAM_PURPOSE,
      expires_in: PlaybackController::SIDECAR_STREAM_TOKEN_TTL
    )
  end

  def success(reason: nil, song_id: nil, device_ids: [])
    Result.new(ok: true, error: nil, reason: reason, song_id: song_id, device_ids: device_ids)
  end

  def failure(error)
    Result.new(ok: false, error: error, reason: nil, song_id: nil, device_ids: [])
  end
end
