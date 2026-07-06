# frozen_string_literal: true

# BroadcastSource is the seam that maps a domain subject — a Radio_Station or a
# Co_Listen_Session — onto the arguments the Broadcaster control API expects
# (task 9.3). It answers three questions the lifecycle services and the boot-time
# ResumeStreamsJob all need when they drive the Broadcaster:
#
#   * `identifier(subject)` — the stable broadcast id the Broadcaster keys its
#     internal stream handle by (`"radio_station:42"` / `"co_listen_session:7"`).
#   * `kind(subject)`       — which broadcast flavor (`radio` / `co_listen`).
#   * `next_source(subject)` — the next resolved source to encode: a Song
#     (resolved path + a signed stream token the Broadcaster fetches audio with)
#     or a `continuity` directive when nothing is currently resolvable.
#
# The selection itself is delegated to the pure ProgramSequencer (which never
# exhausts and yields `:continuity` when nothing is playable — Req 2.3, 2.5, 7.9)
# and the path/token resolution reuses the same PathResolver + signed-id pattern
# PlaybackController uses to hand a stream to the playback sidecar. Keeping this
# mapping in one place means the lifecycle services and the resume job agree on
# exactly what a "source" is, and it stays injectable for tests (the resolver is
# swappable).
class BroadcastSource
  # Purpose namespace and TTL for the signed, song-scoped stream token handed to
  # the Broadcaster so it can fetch a Song's audio from this Server without a
  # login session (mirrors PlaybackController::SIDECAR_STREAM_PURPOSE). A fresh
  # token is minted for every resolved source; a short TTL bounds a leak.
  SIGNED_STREAM_PURPOSE = :broadcaster_stream
  STREAM_TOKEN_TTL = 6.hours

  # Source directive types on the wire to the Broadcaster.
  SOURCE_SONG = "song"
  SOURCE_CONTINUITY = "continuity"

  # Broadcast flavors on the wire to the Broadcaster.
  KIND_RADIO = "radio"
  KIND_CO_LISTEN = "co_listen"

  # @param resolver [PathResolver] injectable stream-path resolver seam
  def initialize(resolver: PathResolver.new)
    @resolver = resolver
  end

  # The Broadcaster-facing broadcast id for `subject`. Derived from the record's
  # class + id so it is stable across restarts (the resume job re-derives the
  # same id to re-establish the broadcast).
  #
  # @param subject [RadioStation, CoListenSession]
  # @return [String]
  def identifier(subject)
    "#{subject.class.name.underscore}:#{subject.id}"
  end

  # The broadcast flavor for `subject`.
  #
  # @param subject [RadioStation, CoListenSession]
  # @return [String, nil]
  def kind(subject)
    case subject
    when RadioStation then KIND_RADIO
    when CoListenSession then KIND_CO_LISTEN
    end
  end

  # The next resolved source for `subject`, driven by a ProgramSequencer
  # decision. A Radio_Station selects from its eligible-song set (Req 2.2, 2.3);
  # a Co_Listen_Session advances through its Shared_Playlist and loops at its end
  # (Req 6.7, 7.8). When nothing is resolvable — an empty eligible set / empty
  # playlist, or a Song whose stream cannot be resolved — a `continuity`
  # directive keeps the stream open (Req 2.5, 7.9).
  #
  # @param subject [RadioStation, CoListenSession]
  # @param history [Enumerable] recently played song ids, oldest first
  # @return [Hash] the source directive for POST /broadcasts(/:id/next)
  def next_source(subject, history: [])
    case subject
    when RadioStation
      resolve(
        ProgramSequencer.next_selection(
          subject.eligible_songs, history: history, mode: ProgramSequencer::MODE_STATION
        )
      )
    when CoListenSession
      ordered = subject.shared_playlist&.ordered_song_ids || []
      resolve(
        ProgramSequencer.next_selection(
          ordered, history: history, mode: ProgramSequencer::MODE_PLAYLIST
        )
      )
    else
      continuity_source
    end
  end

  private

  # Turn a ProgramSequencer::Selection into a Broadcaster source directive. A
  # `:continuity` selection, a missing Song, or a Song with no resolvable stream
  # all yield continuity so the stream is never closed for lack of a source.
  def resolve(selection)
    return continuity_source if selection.continuity?

    song = Song.find_by(id: selection.song_id)
    return continuity_source if song.nil?

    resolve_song_source(song)
  end

  def resolve_song_source(song)
    stream = @resolver.resolve_stream(song)
    return continuity_source unless stream[:available]

    {
      type: SOURCE_SONG,
      song_id: song.id,
      stream_source: stream[:stream_source],
      stream_url: stream[:resolved_stream_path],
      stream_token: song.signed_id(purpose: SIGNED_STREAM_PURPOSE, expires_in: STREAM_TOKEN_TTL)
    }
  end

  def continuity_source
    { type: SOURCE_CONTINUITY }
  end
end
