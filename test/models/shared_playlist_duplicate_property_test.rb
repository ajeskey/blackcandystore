# frozen_string_literal: true

require "test_helper"

# Property-based test for the duplicate-policy seam of SharedPlaylistAddService
# (design Property 20).
#
# Property 20 concerns *only* how an addition of a Song already present in the
# Shared_Playlist is resolved by the session's configured `duplicate_policy`:
#
#   * under `reject` the addition is refused (DuplicateRejected) and the
#     Shared_Playlist is left completely unchanged, while
#   * under `allow` the Song is appended again.
#
# To isolate the duplicate decision from the per-Guest quota/rate rules
# (Property 19), every addition here is a Host add — Host adds are never
# quota/rate limited, so the only rule that can reject an addition is the
# duplicate policy. Song ids are plain integers (a Shared_Playlist_Entry only
# requires a `song_id`), so a small id pool guarantees duplicate attempts occur
# frequently within a generated sequence.
#
# Each iteration replays a generated add sequence one addition at a time,
# maintaining an independent expected ordered-id list, and asserts after every
# addition that the persisted playlist matches — so a rejected duplicate that
# silently mutated the playlist, or an accepted duplicate that failed to append,
# is caught immediately.
class SharedPlaylistDuplicatePropertyTest < ActiveSupport::TestCase
  # Feature: radio-party-colisten, Property 20: Duplicate policy is honored
  test "adding a Song already present applies the session duplicate policy: reject refuses and leaves the playlist unchanged, allow appends the duplicate" do
    check_property(iterations: 100) do
      # The session's duplicate policy under test, and an add sequence drawn
      # from a deliberately small id pool (1..4) so the same Song is attempted
      # more than once — exercising the duplicate branch under both policies.
      policy = choose("reject", "allow")
      sequence = Array.new(range(1, 12)) { range(1, 4) }

      [ policy, sequence ]
    end.check do |(policy, sequence)|
      reset_feature_data!
      host = build_host
      session = PartySession.create!(user: host, duplicate_policy: policy)
      playlist = SharedPlaylist.create!(sessionable: session)

      # The order-preserving list of song ids we expect the playlist to hold.
      expected = []

      sequence.each_with_index do |song_id, step|
        already_present = expected.include?(song_id)
        service = SharedPlaylistAddService.new(shared_playlist: playlist, host: host)

        if policy == "reject" && already_present
          # A duplicate under `reject` is refused and changes nothing (Req 5.10).
          before = playlist.reload.ordered_song_ids
          assert_raises(SharedPlaylistAddService::DuplicateRejected) do
            service.add(song_id)
          end
          assert_equal before, playlist.reload.ordered_song_ids,
            "a rejected duplicate must leave the Shared_Playlist unchanged (step #{step})"
        else
          # A new Song under either policy, or any Song under `allow`, appends
          # (Req 5.10). Under `allow` the duplicate is appended again.
          entry = service.add(song_id)
          assert_equal song_id, entry.song_id
          expected << song_id
        end

        assert_equal expected, playlist.reload.ordered_song_ids,
          "the playlist must reflect exactly the accepted additions in order (step #{step})"
      end

      # Cross-check the end state against the policy: `reject` yields a
      # duplicate-free playlist preserving first-seen order; `allow` yields the
      # full sequence verbatim.
      if policy == "reject"
        assert_equal sequence.uniq, playlist.reload.ordered_song_ids,
          "under reject the playlist is the sequence with later duplicates dropped"
      else
        assert_equal sequence, playlist.reload.ordered_song_ids,
          "under allow the playlist is the full add sequence including duplicates"
      end
    end
  end

  private

  # A fresh Host user for the session. Each iteration gets its own so no state
  # leaks between generated sequences.
  def build_host
    User.create!(email: "dup-policy-host-#{SecureRandom.uuid}@example.com", password: "foobar123")
  end

  # Remove all feature-owned rows created by prior iterations so each iteration
  # observes only the session/playlist it builds.
  def reset_feature_data!
    SharedPlaylistEntry.delete_all
    SharedPlaylist.delete_all
    PartySession.delete_all
    User.where("email LIKE ?", "dup-policy-host-%@example.com").delete_all
  end
end
