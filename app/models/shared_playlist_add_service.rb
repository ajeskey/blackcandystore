# frozen_string_literal: true

# SharedPlaylistAddService is the pure decision + append seam for contributing a
# Song to a Shared_Playlist, shared by Party_Sessions and Co_Listen_Sessions.
#
# It enforces, in order and before any persistence, the three rules the session
# configures for Guest contributions:
#
#   1. Per-Guest add quota and add rate (Req 5.9). A Guest whose lifetime quota
#      is reached, or who is adding faster than the configured per-minute rate,
#      is rejected with a RateLimited error and the Shared_Playlist is left
#      completely unchanged for that rejected addition (no entry appended, no
#      quota/rate counter advanced). Host adds are never quota/rate limited —
#      the caps are per-Guest.
#   2. Duplicate policy (Req 5.10). When the Song is already present, the
#      session's `duplicate_policy` decides: `reject` refuses the addition with
#      a DuplicateRejected error and leaves the Shared_Playlist unchanged;
#      `allow` appends the Song again.
#   3. Attribution (Req 5.12). An accepted addition is appended with adder
#      attribution — the Guest (recording its id and a snapshot of its optional
#      display name) when a Guest added it, otherwise the Host.
#
# The accept/reject decision (`#decision`) is pure over the current state: it
# reads the Guest's counters, the session's policy, and the playlist contents
# but performs no writes, so it is directly testable. `#add` applies that
# decision, performing the append and advancing the Guest's quota/rate window
# only when the addition is accepted.
class SharedPlaylistAddService
  # Base class for a rejected addition. Rejections never mutate the
  # Shared_Playlist (Req 5.9, 5.10).
  class Error < StandardError; end

  # Raised when a Guest's addition exceeds the configured per-Guest add quota or
  # add rate (Req 5.9).
  class RateLimited < Error; end

  # Raised when a Song already present is added under the `reject` duplicate
  # policy (Req 5.10).
  class DuplicateRejected < Error; end

  # The pure outcome of evaluating an addition against the session's rules. When
  # `accepted?` is false, `reason` explains which rule rejected it
  # (`:rate_limited` or `:duplicate`); no side effect is ever implied by a
  # Decision on its own.
  Decision = Struct.new(:outcome, :reason, keyword_init: true) do
    def accepted?
      outcome == :accepted
    end

    def rejected?
      !accepted?
    end
  end

  # Convenience entry point mirroring the other service seams: evaluate and
  # apply an addition in one call. Returns the created SharedPlaylistEntry on
  # acceptance, or raises RateLimited / DuplicateRejected on rejection.
  #
  # @param shared_playlist [SharedPlaylist] the playlist to append to
  # @param song_id [Integer] the Song being added
  # @param guest [Guest, nil] the adding Guest, or nil for a Host add
  # @param host [User, nil] the adding Host, or nil for a Guest add
  # @param now [Time] the reference time for rate accounting
  # @return [SharedPlaylistEntry] the appended entry
  def self.call(shared_playlist:, song_id:, guest: nil, host: nil, now: Time.current)
    new(shared_playlist: shared_playlist, guest: guest, host: host, now: now).add(song_id)
  end

  # @param shared_playlist [SharedPlaylist] the playlist to append to
  # @param guest [Guest, nil] the adding Guest, mutually exclusive with `host`
  # @param host [User, nil] the adding Host, mutually exclusive with `guest`
  # @param now [Time] the reference time for rate accounting
  def initialize(shared_playlist:, guest: nil, host: nil, now: Time.current)
    raise ArgumentError, "shared_playlist is required" if shared_playlist.nil?

    if guest.nil? && host.nil?
      raise ArgumentError, "an addition must be attributed to a guest or a host"
    end
    if guest.present? && host.present?
      raise ArgumentError, "an addition cannot be attributed to both a guest and a host"
    end

    @shared_playlist = shared_playlist
    @guest = guest
    @host = host
    @now = now
  end

  attr_reader :shared_playlist, :guest, :host, :now

  # The pure accept/reject decision for adding `song_id`, evaluated against the
  # current Guest counters, session duplicate policy, and playlist contents. No
  # side effects (Req 5.9, 5.10).
  def decision(song_id)
    if guest.present?
      if guest.add_quota_exceeded?
        return Decision.new(outcome: :rejected, reason: :rate_limited)
      end
      if guest.rate_limited?(now: now)
        return Decision.new(outcome: :rejected, reason: :rate_limited)
      end
    end

    if duplicate?(song_id) && reject_duplicates?
      return Decision.new(outcome: :rejected, reason: :duplicate)
    end

    Decision.new(outcome: :accepted, reason: nil)
  end

  # Evaluate and, when accepted, apply the addition of `song_id`. On rejection
  # nothing is written: no entry is appended and the Guest's quota/rate counters
  # are untouched (Req 5.9, 5.10). On acceptance the entry is appended with
  # adder attribution and, for a Guest add, the quota/rate window is advanced
  # (Req 5.12).
  #
  # @param song_id [Integer] the Song being added
  # @return [SharedPlaylistEntry] the appended entry
  # @raise [RateLimited] when the Guest exceeds the add quota or rate (Req 5.9)
  # @raise [DuplicateRejected] when a duplicate is refused by policy (Req 5.10)
  def add(song_id)
    result = decision(song_id)

    unless result.accepted?
      case result.reason
      when :rate_limited
        raise RateLimited, "guest has exceeded the configured add quota or rate"
      when :duplicate
        raise DuplicateRejected, "song is already present and duplicates are rejected"
      else
        raise Error, "addition was rejected"
      end
    end

    ApplicationRecord.transaction do
      entry = append!(song_id)
      guest&.record_add!(now: now)
      entry
    end
  end

  private

  # True when `song_id` is already an entry in the Shared_Playlist.
  def duplicate?(song_id)
    shared_playlist.entries.exists?(song_id: song_id)
  end

  # Whether the session rejects duplicate additions. Defaults to rejecting when
  # no session/policy is resolvable, matching the model default (Req 5.10).
  def reject_duplicates?
    policy = shared_playlist.sessionable&.duplicate_policy
    policy.blank? || policy.to_s == "reject"
  end

  # Append the Song with adder attribution (Req 5.12): a Guest records its id
  # and a snapshot of its optional display name; a Host records its user id.
  def append!(song_id)
    attributes = { song_id: song_id }

    if guest.present?
      attributes[:added_by_guest_id] = guest.id
      attributes[:guest_display_name] = guest.display_name
    else
      attributes[:added_by_user_id] = host.id
    end

    shared_playlist.entries.create!(attributes)
  end
end
