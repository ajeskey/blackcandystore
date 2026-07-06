# frozen_string_literal: true

require "test_helper"

# Property-based test for the adder-attribution behavior of
# SharedPlaylistAddService (design Property 21).
#
# Property 21 — Every entry is attributed to its adder: for any sequence of
# additions by Hosts and Guests, each Shared_Playlist entry's attribution
# equals the participant that added it — a Guest add carries that Guest's id
# plus a snapshot of its optional display name (and no host attribution), and a
# Host add carries that Host's user id (and no guest attribution).
#
# The service is exercised directly (no controller, no Broadcaster). Each
# iteration builds an isolated session with unlimited add quota/rate and an
# `allow` duplicate policy so that every generated addition is *accepted* — this
# property is about the attribution of accepted entries, not about the
# quota/duplicate rejection paths (which Properties 19 and 20 cover). A distinct
# set of Guests (some with a display name, some with a blank name, some with
# none at all) and a distinct Host add are interleaved in a generated order so
# the attribution logic is genuinely mixed across adders.
#
# The display-name *snapshot* is verified too: after every addition, each
# Guest's display name is changed, and the persisted entries are re-read to
# confirm they still carry the name captured at add time (Req 5.12).
class SharedPlaylistAttributionPropertyTest < ActiveSupport::TestCase
  # Sentinel adder index meaning "the Host added this entry".
  HOST = -1

  setup do
    @host = users(:admin)
    @seq = 0
  end

  # Feature: radio-party-colisten, Property 21: Every entry is attributed to its adder
  test "each accepted entry is attributed to exactly the participant that added it, with the guest's display name snapshotted at add time" do
    check_property(iterations: 100) do
      # A pool of Guests, each with an optional display name (none / blank /
      # a generated name), and a sequence of adds referencing either the Host
      # (HOST) or one of the Guests by index.
      num_guests = range(1, 4)
      guest_names = Array.new(num_guests) do
        case choose(:none, :blank, :name)
        when :none then nil
        when :blank then ""
        else sized(range(1, 12)) { string(:alnum) }
        end
      end
      num_adds = range(1, 12)
      adds = Array.new(num_adds) { range(HOST, num_guests - 1) }
      party = choose(true, false)

      [ party, guest_names, adds ]
    end.check do |(party, guest_names, adds)|
      reset_feature_data!

      session = build_session(party)
      playlist = SharedPlaylist.create!(sessionable: session)
      guests = guest_names.map { |name| build_guest(session, name) }

      # Apply the generated sequence, recording for each appended entry the
      # attribution we expect it to carry.
      expectations = adds.each_with_index.map do |adder_index, i|
        song_id = i + 1

        entry =
          if adder_index == HOST
            SharedPlaylistAddService.call(shared_playlist: playlist, song_id: song_id, host: @host)
          else
            guest = guests[adder_index]
            SharedPlaylistAddService.call(shared_playlist: playlist, song_id: song_id, guest: guest)
          end

        expected =
          if adder_index == HOST
            { kind: :host, user_id: @host.id }
          else
            guest = guests[adder_index]
            { kind: :guest, guest_id: guest.id, name: guest.display_name }
          end

        [ entry.id, expected ]
      end

      # Every add was accepted, so there is exactly one entry per add.
      assert_equal adds.length, playlist.reload.entries.count,
        "every accepted addition must append exactly one entry"

      assert_attribution(expectations)

      # The display name is a snapshot: mutating each Guest's current name must
      # not change the attribution already recorded on its entries (Req 5.12).
      guests.each_with_index do |guest, i|
        guest.update!(display_name: "renamed-#{next_seq}-#{i}")
      end

      assert_attribution(expectations)
    end
  end

  private

  def next_seq
    @seq += 1
  end

  # Reset all Shared_Playlist / Guest / session state so each iteration observes
  # only the data it builds. `song_id` is a plain integer, so no Song/Album/etc.
  # rows are involved.
  def reset_feature_data!
    SharedPlaylistEntry.delete_all
    SharedPlaylist.delete_all
    Guest.delete_all
    PartySession.delete_all
    CoListenSession.delete_all
  end

  # A session with unbounded guest add quota/rate and an `allow` duplicate
  # policy so every generated addition is accepted. Exercises both session kinds
  # to confirm attribution is independent of the polymorphic sessionable.
  def build_session(party)
    klass = party ? PartySession : CoListenSession
    klass.create!(
      user: @host,
      guest_add_quota: nil,
      guest_add_rate_per_minute: nil,
      duplicate_policy: :allow
    )
  end

  def build_guest(session, display_name)
    Guest.create!(
      sessionable: session,
      display_name: display_name,
      token: SecureRandom.hex(16)
    )
  end

  # Assert every recorded entry still carries exactly the attribution of the
  # participant that added it: a guest add binds the guest id + display-name
  # snapshot and no host id; a host add binds the host user id and no guest id.
  def assert_attribution(expectations)
    expectations.each do |entry_id, expected|
      entry = SharedPlaylistEntry.find(entry_id)

      case expected[:kind]
      when :host
        assert_equal expected[:user_id], entry.added_by_user_id,
          "a host add must be attributed to the host's user id"
        assert_nil entry.added_by_guest_id,
          "a host add must carry no guest attribution"
        assert_nil entry.guest_display_name,
          "a host add must carry no guest display name"
      when :guest
        assert_equal expected[:guest_id], entry.added_by_guest_id,
          "a guest add must be attributed to the adding guest's id"
        assert_nil entry.added_by_user_id,
          "a guest add must carry no host attribution"
        if expected[:name].nil?
          assert_nil entry.guest_display_name,
            "a guest add with no display name must snapshot nil"
        else
          assert_equal expected[:name], entry.guest_display_name,
            "a guest add must snapshot the guest's display name at add time"
        end
      end
    end
  end
end
