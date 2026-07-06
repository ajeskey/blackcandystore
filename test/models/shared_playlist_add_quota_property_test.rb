# frozen_string_literal: true

require "test_helper"

# Property-based test for the SharedPlaylistAddService quota/rate seam of the
# radio-party-colisten feature (design Property 19).
#
# Property 19 (Req 5.9): For any sequence of a Guest's add attempts against a
# configured per-Guest add quota and add rate, the number of accepted additions
# never exceeds the quota or the rate allowance for the window; each rejected
# addition returns a rate-limit error and leaves the Shared_Playlist unchanged
# for that addition (no entry appended, no quota/rate counter advanced).
#
# Each iteration builds an isolated Party_Session with a generated quota and
# per-minute rate, admits a single Guest, and replays a generated sequence of
# add attempts at generated points in time. Every Song added is distinct, so the
# duplicate policy is never in play and the accept/reject outcome is governed
# purely by the quota and rate rules under test.
#
# For every attempt the test independently predicts — from the Guest's current
# counters and the reference time — whether the add must be accepted or rejected
# under Req 5.9, then asserts:
#   * the raised/returned outcome matches that prediction, and
#   * on rejection nothing changed (playlist size, add_count, rate window all
#     held), while on acceptance exactly one entry was appended, the quota
#     counter advanced by one, and the rate window advanced to the add time.
# A final invariant check confirms the total accepted count never exceeds the
# configured quota.
class SharedPlaylistAddQuotaPropertyTest < ActiveSupport::TestCase
  # A fixed base instant so time deltas are deterministic and shrinkable.
  BASE_TIME = Time.zone.local(2026, 1, 1, 12, 0, 0)

  # Feature: radio-party-colisten, Property 19: Per-Guest add quota and rate are enforced without side effects on rejection
  test "a guest add that would exceed the configured quota or rate is rejected with a rate-limit error and leaves the shared playlist and guest counters unchanged, while accepted adds advance them and never exceed the quota" do
    check_property(iterations: 100) do
      # nil quota/rate = unbounded; 0 quota = never accept; 0 rate = unbounded.
      quota = choose(nil, 0, 1, 2, 3, 5)
      rate = choose(nil, 0, 1, 2, 6, 30, 60)
      # A sequence of add attempts, each preceded by an inter-attempt delay in
      # seconds. Small delays force the rate window to reject; large ones clear
      # it, so both branches are exercised.
      attempt_count = range(1, 8)
      delays = Array.new(attempt_count) { range(0, 120) }

      [ quota, rate, delays ]
    end.check do |(quota, rate, delays)|
      reset_feature_data!

      host = User.create!(email: "quota-host-#{SecureRandom.uuid}@example.com", password: "foobar123")
      session = PartySession.create!(
        user: host,
        guest_add_quota: quota,
        guest_add_rate_per_minute: rate,
        duplicate_policy: :allow
      )
      playlist = SharedPlaylist.create!(sessionable: session)
      guest = Guest.create!(sessionable: session, token: SecureRandom.hex(16), display_name: "Guest")

      now = BASE_TIME
      accepted = 0
      next_song_id = 0

      delays.each do |delay|
        now += delay.seconds

        # Independent prediction from the Guest's current state (Req 5.9): a
        # quota is exceeded once add_count has reached it; the rate blocks when
        # the last accepted add is closer than 60/rate seconds ago.
        quota_exceeded = quota.present? && guest.add_count >= quota
        rate_blocked =
          rate.present? && rate.positive? &&
          guest.rate_window_started_at.present? &&
          (now - guest.rate_window_started_at) < (60.0 / rate)
        expected_accept = !quota_exceeded && !rate_blocked

        size_before = playlist.entries.count
        count_before = guest.add_count
        window_before = guest.rate_window_started_at

        next_song_id += 1
        rejected = false
        begin
          SharedPlaylistAddService.call(
            shared_playlist: playlist,
            song_id: next_song_id,
            guest: guest,
            now: now
          )
        rescue SharedPlaylistAddService::RateLimited
          rejected = true
        end

        assert_equal expected_accept, !rejected,
          "quota=#{quota.inspect} rate=#{rate.inspect}: add acceptance must match the quota/rate rule"

        if rejected
          # No side effects on a rejected addition (Req 5.9).
          assert_equal size_before, playlist.entries.count,
            "a rejected add must not append an entry"
          assert_equal count_before, guest.add_count,
            "a rejected add must not advance the quota counter"
          assert guest.rate_window_started_at == window_before,
            "a rejected add must not advance the rate window"
        else
          accepted += 1
          assert_equal size_before + 1, playlist.entries.count,
            "an accepted add must append exactly one entry"
          assert_equal count_before + 1, guest.add_count,
            "an accepted add must advance the quota counter by one"
          assert_equal now, guest.rate_window_started_at,
            "an accepted add must advance the rate window to the add time"
        end
      end

      if quota.present?
        assert accepted <= quota,
          "the number of accepted additions (#{accepted}) must never exceed the quota (#{quota})"
      end
    end
  end

  private

  # Remove all feature session/guest/playlist rows so each iteration observes
  # only the dataset it builds. These tables carry no fixtures.
  def reset_feature_data!
    SharedPlaylistEntry.delete_all
    SharedPlaylist.delete_all
    Guest.delete_all
    PartySession.delete_all
    CoListenSession.delete_all
  end
end
