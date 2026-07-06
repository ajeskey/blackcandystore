# frozen_string_literal: true

require "test_helper"

# Property-based test for the revocation seam of the radio-party-colisten
# feature (design Property 17).
#
# Design property (radio-party-colisten, Property 17):
#   For any Party_Session or Co_Listen_Session, revoking it marks the backing
#   Access_Grant revoked so that no further Guest may join, revocation is
#   irreversible, and Guests admitted before revocation retain access until the
#   session expires or ends.
#
#   Validates: Requirements 4.6, 8.5
#
# Two seams collaborate to produce this behavior, and this test exercises both
# together against real persisted records:
#
#   * ShareLinkService#revoke transitions every AccessGrant backing the
#     session's Share_Links to `revoked` (the terminal enum state).
#   * GuestAccessResolver gates *new* joins on `new_join_allowed?(grant)` (i.e.
#     `grant.usable?`), which a revoked grant fails, while its live-state gate
#     `access_valid?(session:, guest:)` deliberately does NOT consult
#     revocation — it only reads session active/expiry and guest removal.
#
# So the property splits cleanly into three checks per iteration:
#   1. Before revocation every backing grant is usable and admission succeeds.
#   2. After revocation every backing grant is revoked (and stays revoked —
#      revocation is terminal), a fresh admission attempt is refused with
#      `:unauthorized` and creates no Guest, yet every Guest admitted before the
#      revocation still passes `access_valid?` because the session is still
#      active and unexpired.
#
# The session is always built `active` with an unexpired (perpetual or
# future-dated) duration so that the only thing changing across the revoke
# boundary is the grant's revocation — isolating exactly what Property 17
# governs (session end/expiry are Property 16's concern, not tested here).
class RevocationPropertyTest < ActiveSupport::TestCase
  # A readable directory so freshly created local libraries pass media-path
  # validation; the fixtures directory always exists.
  MEDIA_PATH = Rails.root.join("test", "fixtures", "files").to_s
  USER_EMAIL_PREFIX = "revocation-prop-host"
  LIBRARY_NAME_PREFIX = "RevocationProp-Lib"

  setup do
    @seq = 0
  end

  # Feature: radio-party-colisten, Property 17: Revocation is terminal and blocks only new joins
  test "revoking a session terminally blocks new joins while guests admitted before revocation retain access on the still-active, unexpired session" do
    check_property(iterations: 100) do
      # A Party_Session or Co_Listen_Session (both share the seam), sharing 1..3
      # libraries (=> that many backing grants), with 0..5 Guests admitted
      # before revocation, and an unexpired duration (perpetual, or a positive
      # number of future hours/days) so the session never expires mid-test.
      party = choose(true, false)
      lib_count = range(1, 3)
      pre_admits = range(0, 5)
      duration_kind = choose("perpetual", "hours", "days")
      duration_value = range(1, 72)

      [ party, lib_count, pre_admits, duration_kind, duration_value ]
    end.check do |(party, lib_count, pre_admits, duration_kind, duration_value)|
      reset_dataset!
      host = build_host

      shared_ids = Array.new(lib_count) { build_local_library(host).id }
      session = build_session(party, host, shared_ids, duration_kind, duration_value)

      links = ShareLinkService.generate(session)
      grants = links.map(&:access_grant)

      # --- Before revocation: joins are open --------------------------------
      grants.each do |grant|
        assert GuestAccessResolver.new_join_allowed?(grant),
          "a usable backing grant must allow new joins before revocation"
      end

      admitted = Array.new(pre_admits) do
        result = GuestAccessResolver.admit(session: session, grant: grants.first)
        assert result.ok?, "admission through a usable grant must succeed before revocation"
        result.guest
      end

      # Every pre-revocation Guest is valid on the active, unexpired session.
      admitted.each do |guest|
        assert GuestAccessResolver.access_valid?(session: session, guest: guest),
          "an admitted guest must be valid on an active, unexpired session"
      end
      count_before = GuestAccessResolver.current_guest_count(session)
      assert_equal pre_admits, count_before

      # --- Revoke -----------------------------------------------------------
      revoked_count = ShareLinkService.revoke(session)
      assert_equal grants.length, revoked_count,
        "revoke must transition every backing grant that was active"

      # --- After revocation: new joins are terminally blocked ---------------
      grants.each do |grant|
        grant.reload
        assert grant.revoked?, "revoke must mark every backing grant revoked"
        assert_not grant.usable?, "a revoked grant is never usable"
        assert_not GuestAccessResolver.new_join_allowed?(grant),
          "a revoked backing grant must block new joins"
      end

      # A fresh admission attempt is refused with :unauthorized and creates no
      # Guest or token (no side effects on rejection).
      fresh_grant = AccessGrant.find(grants.first.id)
      denied = GuestAccessResolver.admit(session: session, grant: fresh_grant)
      assert denied.denied?, "admission through a revoked grant must be refused"
      assert_equal GuestAccessResolver::ERROR_UNAUTHORIZED, denied.error,
        "a revoked grant refuses admission with :unauthorized"
      assert_nil denied.guest, "a refused admission must not create a Guest"
      assert_nil denied.token, "a refused admission must not issue a token"
      assert_equal count_before, GuestAccessResolver.current_guest_count(session),
        "a refused admission must leave the guest count unchanged"

      # --- Revocation is terminal + only new joins are blocked --------------
      # A second revoke is idempotent and the grants stay revoked (irreversible).
      assert_equal 0, ShareLinkService.revoke(session),
        "re-revoking a fully revoked session transitions nothing (terminal)"
      grants.each do |grant|
        grant.reload
        assert grant.revoked?, "revocation is terminal: grants remain revoked"
      end

      # Guests admitted before revocation retain access — the live-state gate
      # never consults revocation, only session active/expiry and guest removal.
      admitted.each do |guest|
        guest.reload
        assert GuestAccessResolver.access_valid?(session: session, guest: guest),
          "a guest admitted before revocation retains access while the session " \
          "stays active and unexpired (revocation blocks only new joins)"
      end
    end
  end

  private

  def next_seq
    @seq += 1
  end

  # Wipe every record built by prior iterations so each iteration observes only
  # the dataset it creates.
  def reset_dataset!
    Guest.delete_all
    ShareLink.delete_all
    AccessGrant.delete_all
    PartySession.delete_all
    CoListenSession.delete_all
    Library.where("name LIKE ?", "#{LIBRARY_NAME_PREFIX}-%").delete_all
    User.where("email LIKE ?", "#{USER_EMAIL_PREFIX}-%@example.com").delete_all
  end

  # A fresh Host user; its owned local libraries form its authorized set.
  def build_host
    User.create!(email: "#{USER_EMAIL_PREFIX}-#{SecureRandom.uuid}@example.com", password: "foobar123")
  end

  # A local library owned by (and therefore authorized to) the host.
  def build_local_library(host)
    Library.create!(
      name: "#{LIBRARY_NAME_PREFIX}-#{next_seq}-#{SecureRandom.uuid}",
      kind: "local",
      media_path: MEDIA_PATH,
      owner: host
    )
  end

  # A valid active session of the chosen kind, sharing the host's libraries with
  # an unexpired Session_Duration (perpetual carries no value).
  def build_session(party, host, shared_ids, duration_kind, duration_value)
    klass = party ? PartySession : CoListenSession
    klass.create!(
      user: host,
      state: :active,
      shared_library_ids: shared_ids,
      session_duration_kind: duration_kind,
      session_duration_value: duration_kind == "perpetual" ? nil : duration_value
    )
  end
end
