# frozen_string_literal: true

require "test_helper"

# Property-based test for the Shared_Playlist entry mutation authority seam of
# the radio-party-colisten feature (design Property 22).
#
# AuthorizationPolicy.entry_mutation_authorized?(actor:, entry:, session:) is the
# pure predicate the contribution controllers consult before removing or
# reordering a Shared_Playlist_Entry. The rule (Req 6.6) is:
#
#   permitted iff the actor is the Host of the session (a full User account whose
#   id is the session's owning user_id), OR the actor is the Guest that added
#   that specific entry (a Guest whose id equals entry.added_by_guest_id). A
#   Guest attempting another participant's entry — or a Host-added entry — is
#   rejected, and any non-participant (another User or an anonymous caller) is
#   rejected too.
#
# Each iteration builds an isolated session (Party_Session or Co_Listen_Session)
# with a Shared_Playlist holding one entry attributed to either the Host or a
# specific Guest, then evaluates the predicate for a generated actor kind
# (host, the entry's adding guest, another guest, another user, or nil). Because
# the predicate is pure — it reads state and returns a boolean, mutating nothing
# — the entry's persisted attributes are snapshotted before and after the
# decision to confirm a rejection leaves the playlist unchanged.
class PlaylistMutationAuthorityPropertyTest < ActiveSupport::TestCase
  # Who a generated entry is attributed to: the Host, or the specific Guest
  # `guest_a`.
  ENTRY_OWNERS = %i[host guest_a].freeze

  # The actor kinds exercised against every entry. Only the Host (always) and
  # `guest_a` when it added the entry are ever authorized.
  ACTOR_KINDS = %i[host guest_a guest_b other_user nil].freeze

  setup { @seq = 0 }

  # Feature: radio-party-colisten, Property 22: Playlist mutation authority
  test "removing or reordering a shared-playlist entry is authorized iff the actor is the host or the guest that added that specific entry, and a rejected decision leaves the entry unchanged" do
    check_property(iterations: 100) do
      session_kind = choose(:party, :colisten)
      entry_owner = choose(*ENTRY_OWNERS)
      actor_kind = choose(*ACTOR_KINDS)

      [ session_kind, entry_owner, actor_kind ]
    end.check do |(session_kind, entry_owner, actor_kind)|
      reset_dataset!
      host = create_user

      session = build_session(session_kind, host)
      playlist = SharedPlaylist.create!(sessionable: session)

      # Two distinct Guests admitted to this session: guest_a may own the entry,
      # guest_b never does.
      guest_a = Guest.create!(sessionable: session, token: "guest-a-#{next_seq}")
      guest_b = Guest.create!(sessionable: session, token: "guest-b-#{next_seq}")

      entry = build_entry(playlist, entry_owner, host, guest_a)
      actor = build_actor(actor_kind, host, guest_a, guest_b)

      # Permitted iff the actor is the Host, or the actor is the Guest that added
      # this specific entry.
      expected =
        actor_kind == :host ||
        (actor_kind == :guest_a && entry_owner == :guest_a)

      before = entry.attributes

      permitted = AuthorizationPolicy.entry_mutation_authorized?(actor: actor, entry: entry, session: session)

      assert_equal expected, permitted,
        "#{actor_kind} acting on a #{entry_owner}-added entry in a #{session_kind} session should be " \
        "#{expected ? "permitted" : "rejected"}"

      # A pure decision never mutates the entry — a rejection leaves the playlist
      # exactly as it was (Property 22's "playlist is unchanged").
      entry.reload
      assert_equal before, entry.attributes,
        "evaluating entry-mutation authority must not change the entry"

      # A Guest may never touch another participant's entry, regardless of who
      # owns it: guest_b is never authorized.
      if actor_kind == :guest_b
        assert_not permitted, "a guest is never authorized for an entry it did not add"
      end
    end
  end

  private

  def next_seq
    @seq += 1
  end

  # Wipe every session/guest/playlist record so each iteration observes only the
  # dataset it builds. Users are left in place (created fresh with unique emails).
  def reset_dataset!
    SharedPlaylistEntry.delete_all
    SharedPlaylist.delete_all
    Guest.delete_all
    PartySession.delete_all
    CoListenSession.delete_all
  end

  def create_user
    User.create!(email: "pl-mut-#{SecureRandom.uuid}@example.com", password: "foobar123")
  end

  # A persisted session of the requested kind owned by `host`. An empty
  # shared-library set is a valid subset of any host's authorization.
  def build_session(session_kind, host)
    case session_kind
    when :party then PartySession.create!(user: host)
    when :colisten then CoListenSession.create!(user: host)
    end
  end

  # A persisted Shared_Playlist_Entry attributed to the Host or to `guest_a`.
  # `song_id` is an arbitrary integer (a shared Song may live on a remote
  # library; the entry stores only the id).
  def build_entry(playlist, entry_owner, host, guest_a)
    attrs = { shared_playlist: playlist, song_id: next_seq }
    case entry_owner
    when :host
      attrs[:added_by_user_id] = host.id
    when :guest_a
      attrs[:added_by_guest_id] = guest_a.id
      attrs[:guest_display_name] = "Guest A"
    end
    SharedPlaylistEntry.create!(attrs)
  end

  # The actor for the given kind: the Host User, the entry's adding Guest, a
  # different admitted Guest, an unrelated User, or an anonymous (nil) caller.
  def build_actor(actor_kind, host, guest_a, guest_b)
    case actor_kind
    when :host then host
    when :guest_a then guest_a
    when :guest_b then guest_b
    when :other_user then create_user
    when :nil then nil
    end
  end
end
