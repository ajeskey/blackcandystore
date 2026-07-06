# frozen_string_literal: true

require "test_helper"

# Property-based test for the retained-playlist host-only access seam of
# GuestAccessResolver (design Property 30; Req 12.3).
#
# Property 30 concerns who may read a session's Shared_Playlist across the
# session's whole lifecycle, and especially after teardown:
#
#   * the Host may *always* read the Shared_Playlist — including after the
#     session has ended or its Session_Duration has expired, so the retained
#     playlist stays reviewable by its owner; and
#   * a Guest may read it only while its access is live, i.e. the session is
#     `active`, has not expired, and the Guest has not been removed. The moment
#     the session ends or expires, every Guest request is rejected, so the
#     retained playlist becomes host-only.
#
# The decision lives in `GuestAccessResolver.playlist_readable?(actor:,
# session:, guest:, now:)`, which returns true for the Host unconditionally and
# otherwise defers to the live-state gate `access_valid?`.
#
# This exercises the seam against real Party_Session / Co_Listen_Session records
# with genuinely admitted Guests, realizing each live-state condition as actual
# state: the session `ended` vs `active`, expiry driven off a backing
# Access_Grant's `expires_at` (past = expired, future or perpetual/nil = not
# expired), and the Guest removed vs not. Each iteration rebuilds its own
# feature records (see reset_feature_data!) so nothing leaks between cases.
class RetainedPlaylistPropertyTest < ActiveSupport::TestCase
  # Feature: radio-party-colisten, Property 30: Retained playlist is host-only after teardown
  test "the Host may always read the Shared_Playlist including after teardown, while a Guest may read it only while its access is live (active, unexpired, not removed), so an ended or expired session's playlist is host-only" do
    check_property(iterations: 100) do
      # The three live-state conditions realized independently, plus the session
      # kind and, when not expired, whether "not expired" means a future expiry
      # or a perpetual (no-expiry) grant — both must count as not expired.
      session_active = choose(true, false)
      session_expired = choose(true, false)
      guest_removed = choose(true, false)
      kind = choose("party", "co_listen")
      perpetual_when_unexpired = choose(true, false)

      [ session_active, session_expired, guest_removed, kind, perpetual_when_unexpired ]
    end.check do |(session_active, session_expired, guest_removed, kind, perpetual_when_unexpired)|
      reset_feature_data!
      now = Time.current
      host = build_host

      session = build_session(kind, host)
      # Realize the session's live state: ended vs active.
      session.update!(state: session_active ? "active" : "ended")

      # Realize expiry off a backing Access_Grant's expires_at wired through a
      # Share_Link so GuestAccessResolver#session_expires_at can read it:
      #   * expired      -> a grant that has already expired (past)
      #   * not expired  -> a future expiry, or a perpetual (nil) expiry
      expires_at =
        if session_expired
          now - 1.hour
        elsif perpetual_when_unexpired
          nil
        else
          now + 1.hour
        end
      attach_backing_grant(session, host, expires_at)

      # A genuinely admitted Guest bound to a Guest_Token, then removed or not.
      guest = admit_guest(session, now)
      guest.remove!(now) if guest_removed
      guest.reload

      live = session_active && !session_expired && !guest_removed
      torn_down = !session_active || session_expired
      ctx = "kind=#{kind}, active=#{session_active}, expired=#{session_expired}, " \
        "perpetual=#{perpetual_when_unexpired}, removed=#{guest_removed}"

      # --- Host reads always, including after teardown (Req 12.3) ---
      assert GuestAccessResolver.playlist_readable?(actor: host, session: session, now: now),
        "the Host must always be able to read the Shared_Playlist (#{ctx})"
      # A non-host User (not the owner) is not the Host, so it is not granted
      # host access and, having no Guest identity, is rejected.
      non_host = build_host
      assert_not GuestAccessResolver.playlist_readable?(actor: non_host, session: session, now: now),
        "a non-host User with no Guest identity must not read the Shared_Playlist (#{ctx})"

      # --- Guest reads iff its access is live (Req 12.2, 12.3) ---
      # Passed as the actor directly (a Guest request).
      assert_equal live,
        GuestAccessResolver.playlist_readable?(actor: guest, session: session, now: now),
        "a Guest actor may read the Shared_Playlist iff its access is live (#{ctx})"
      # Passed via the explicit `guest:` param with a nil/host-less actor path:
      # the host branch is skipped and the same live-state gate applies.
      assert_equal live,
        GuestAccessResolver.playlist_readable?(actor: guest, session: session, guest: guest, now: now),
        "the guest: parameter must gate on the same live-state decision (#{ctx})"

      # --- After teardown the playlist is host-only (Req 12.3) ---
      if torn_down
        assert GuestAccessResolver.playlist_readable?(actor: host, session: session, now: now),
          "an ended/expired session's Shared_Playlist must stay readable by the Host (#{ctx})"
        assert_not GuestAccessResolver.playlist_readable?(actor: guest, session: session, now: now),
          "an ended/expired session's Shared_Playlist must be rejected for every Guest (#{ctx})"
      end
    end
  end

  private

  # A fresh User per call so no session/guest state leaks between generated
  # cases (also used to mint a distinct non-host User).
  def build_host
    User.create!(email: "retained-playlist-host-#{SecureRandom.uuid}@example.com", password: "foobar123")
  end

  # Build the requested session kind for `host`, scoped to no shared libraries
  # (library scoping is Property 15's concern, not this one).
  def build_session(kind, host)
    if kind == "party"
      PartySession.create!(user: host, shared_library_ids: [])
    else
      CoListenSession.create!(user: host, shared_library_ids: [])
    end
  end

  # Wire a Share_Link backed by an AccessGrant with the given expiration onto
  # `session`, so GuestAccessResolver reads expiry from real records.
  def attach_backing_grant(session, host, expires_at)
    grant = AccessGrant.create!(
      library: default_library,
      token: "retained-playlist-grant-#{SecureRandom.hex(6)}",
      expires_at: expires_at
    )
    ShareLink.create!(sessionable: session, access_grant: grant)
    grant
  end

  # Create a real admitted Guest bound to a fresh Guest_Token.
  def admit_guest(session, now)
    guest = session.guests.new(admitted_at: now, add_count: 0)
    guest.token = SecureRandom.urlsafe_base64(32)
    guest.save!
    guest
  end

  def default_library
    libraries(:default_library)
  end

  # Remove every feature record touched by this property, ordered to respect
  # foreign keys, so each iteration observes only the session/guest it builds.
  def reset_feature_data!
    Guest.delete_all
    ShareLink.delete_all
    PartySession.delete_all
    CoListenSession.delete_all
    AccessGrant.delete_all
    User.where("email LIKE ?", "retained-playlist-host-%@example.com").delete_all
  end
end
