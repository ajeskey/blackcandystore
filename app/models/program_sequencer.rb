# frozen_string_literal: true

# ProgramSequencer is the Server component that selects the next item for a
# Shared_Stream — either a Radio_Station's eligible-song set or a
# Party_Session / Co_Listen_Session's Shared_Playlist (Req 2.2, 2.3, 2.5, 6.7,
# 7.8, 7.9).
#
# Like PlaybackController, this class is deliberately a PURE, DETERMINISTIC
# function seam. Given a set (or ordered playlist) of song ids plus a small
# amount of "recently played" history it decides the next selection with no
# side effects and no I/O — no database access, no Broadcaster, no clock. This
# is what lets the selection contract be property-tested (Properties 5, 6, 7)
# without standing up the out-of-process Broadcaster. Resolving song ids to
# audio files and actually encoding the stream live in the Broadcaster and are
# exercised by integration tests, NOT here.
#
# Selection contract (design "Program_Sequencer"):
# - It NEVER returns an ineligible item: a station selection is always a member
#   of the eligible set, and a playlist selection is always one of the
#   playlist's entries.
# - It NEVER exhausts while there is something to play. For a station, once
#   every eligible Song has been played it re-selects from the FULL eligible set
#   (Req 2.3), continuing the broadcast indefinitely. For a playlist, once the
#   last entry has played it loops back to the first entry (Req 6.7, 7.8).
# - When nothing is resolvable — an empty eligible set, or an empty
#   Shared_Playlist — it yields a `:continuity` directive rather than closing
#   the stream, keeping it open until an eligible/added Song appears
#   (Req 2.5, 7.9).
#
# Two modes:
# - `MODE_STATION` (default): the source is an unordered *set* of eligible song
#   ids. The next selection prefers a song that has not been played recently and,
#   when all have been played, rotates back to the least-recently-played one.
# - `MODE_PLAYLIST`: the source is an *ordered* list of Shared_Playlist entries.
#   Selection advances through the entries in order and wraps to the beginning
#   after the last entry (the loop-at-end behaviour of Req 6.7 / 7.8).
#
# History is an ordered list of previously played song ids, oldest first and
# most-recently-played last. Callers keep only a bounded, "recently played"
# window; the sequencer tolerates history that contains ids no longer in the
# source (e.g. after a station's criteria changed) by simply ignoring them.
class ProgramSequencer
  # The outcome of a selection. `song?` selections carry the chosen `song_id`;
  # `continuity?` selections carry no song and instruct the caller to emit
  # Continuity_Audio (Req 2.5, 7.9). Modelled as a small value object so callers
  # (and property tests) can pattern-match on the directive without inspecting
  # nil-vs-id sentinels.
  Selection = Struct.new(:type, :song_id, keyword_init: true) do
    def song?
      type == TYPE_SONG
    end

    def continuity?
      type == TYPE_CONTINUITY
    end
  end

  TYPE_SONG = :song
  TYPE_CONTINUITY = :continuity

  # Source is an unordered eligible-song set (Radio_Station).
  MODE_STATION = :station
  # Source is an ordered Shared_Playlist (Party_Session / Co_Listen_Session).
  MODE_PLAYLIST = :playlist

  MODES = [ MODE_STATION, MODE_PLAYLIST ].freeze

  # Convenience one-shot entry point mirroring `PlaybackController.for_user`'s
  # role as the ergonomic constructor.
  #
  # @param source [Enumerable] eligible song ids/records (station) or ordered
  #   Shared_Playlist entries (playlist)
  # @param history [Enumerable] recently played song ids/records, oldest first
  # @param mode [Symbol] MODE_STATION or MODE_PLAYLIST
  # @return [Selection]
  def self.next_selection(source, history: [], mode: MODE_STATION)
    new(source, history: history, mode: mode).next_selection
  end

  # @param source [Enumerable] eligible song ids/records (station) or ordered
  #   Shared_Playlist entries (playlist)
  # @param history [Enumerable] recently played song ids/records, oldest first
  # @param mode [Symbol] MODE_STATION or MODE_PLAYLIST
  def initialize(source, history: [], mode: MODE_STATION)
    raise ArgumentError, "unknown mode #{mode.inspect}" unless MODES.include?(mode)

    @mode = mode
    @source = normalize_ids(source)
    @history = normalize_ids(history)
  end

  attr_reader :mode

  # Decide the next item to play. Pure and deterministic: the same source and
  # history always yield the same Selection.
  #
  # @return [Selection]
  def next_selection
    # Nothing to resolve — keep the stream open with Continuity_Audio rather
    # than reporting exhaustion (Req 2.5, 7.9).
    return continuity if @source.empty?

    case @mode
    when MODE_STATION then next_station_song
    when MODE_PLAYLIST then next_playlist_song
    end
  end

  private

  # Radio_Station selection over the eligible *set* (Req 2.2, 2.3). Prefer an
  # eligible song not in the recently played window, in eligible order. Once
  # every eligible song has been played, re-select from the full set by rotating
  # to the least-recently-played song, so the broadcast never exhausts while the
  # eligible set is non-empty (Req 2.3).
  def next_station_song
    # The eligible set is conceptually a set; collapse any repeats to unique ids
    # while preserving order so selection is stable.
    eligible = @source.uniq
    unplayed = eligible - @history

    return song(unplayed.first) if unplayed.any?

    # Every eligible song has been played: continue from the full eligible set,
    # choosing the one whose most recent play is oldest (least recently played).
    # `rindex` locates the most recent occurrence in the oldest-first history;
    # the smallest such index is the least recently played. `min_by` is stable,
    # so ties resolve to eligible order — keeping the result deterministic.
    song(eligible.min_by { |id| @history.rindex(id) })
  end

  # Shared_Playlist selection over the *ordered* entries (Req 6.7, 7.8). Advance
  # to the entry after the one most recently played, wrapping to the first entry
  # once the last entry has played (loop at end). When nothing in history
  # matches the current entries (e.g. a fresh playlist), start at the first
  # entry.
  def next_playlist_song
    current = @history.reverse_each.find { |id| @source.include?(id) }
    return song(@source.first) if current.nil?

    # Use the last matching position so a song appearing at the end of the
    # playlist loops from that end even if it repeats earlier.
    index = @source.rindex(current)
    song(@source[(index + 1) % @source.length])
  end

  def song(song_id)
    Selection.new(type: TYPE_SONG, song_id: song_id)
  end

  def continuity
    Selection.new(type: TYPE_CONTINUITY, song_id: nil)
  end

  # Coerce an enumerable of song ids or Song-like records to an array of ids,
  # preserving both order and any duplicates. Order matters for playlist looping
  # and for history recency; duplicates matter for a Shared_Playlist that allows
  # the same Song more than once (Req 5.10 `allow` policy). Accepting either
  # records or bare ids keeps the seam usable both from callers that hold
  # ActiveRecord relations and from property tests that generate plain integers.
  def normalize_ids(items)
    Array(items).map { |item| extract_id(item) }.compact
  end

  def extract_id(item)
    item.respond_to?(:id) ? item.id : item
  end
end
