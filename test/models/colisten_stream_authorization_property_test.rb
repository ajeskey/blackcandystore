# frozen_string_literal: true

require "test_helper"

# Property-based tests for the Co_Listen_Session Stream_Endpoint authorization
# seam of the radio-party-colisten feature (design Property 27).
#
# Property 27 governs *who* is allowed to hear a Co_Listen_Session's
# Shared_Stream: audio is served iff the URL carries a guest-derived
# Stream_Token whose underlying Guest access is still valid — the token resolves
# to a Guest bound to this session (token -> Guest -> session), the session is
# still `active` (not ended/torn down), the session's duration has not expired,
# and the Guest has not been removed. A co-listen stream is never served
# publicly, so the guest-derived path is the *only* way in, and the token stops
# authorizing exactly when the Guest's access ends.
#
# This is exercised at two layers:
#   1. The pure `StreamTokenService.guest_access_valid?` decision, over the full
#      boolean input space of its four facts (token_scoped_to_session,
#      session_active, session_expired, guest_removed), asserting the decision
#      is exactly `scoped && active && !expired && !removed` and that flipping
#      any single required condition denies. It also confirms the co-listen
#      stream has no public bypass: `stream_authorized?` fed only the
#      guest-access fact equals that fact.
#   2. The record-based `StreamTokenService.colisten_stream_authorized?`, driven
#      by *real* persisted `Guest` records and *real* derived signed
#      Stream_Tokens (`colisten_token_for` / `colisten_guest_for`), across the
#      session/guest lifecycle: a token for this session vs. another session,
#      active vs. ended session, expired vs. not, removed vs. present Guest, and
#      absent/garbage tokens.
class ColistenStreamAuthorizationPropertyTest < ActiveSupport::TestCase
  # A readable directory so freshly created local libraries pass media-path
  # validation; the fixtures directory always exists.
  MEDIA_PATH = Rails.root.join("test", "fixtures", "files").to_s

  setup do
    @seq = 0
  end

  # Feature: radio-party-colisten, Property 27: Co-listen stream authorization tracks guest access validity
  test "the pure guest_access_valid? decision authorizes iff the token is bound to the session, the session is active and unexpired, and the guest is not removed, and there is no public bypass" do
    check_property(iterations: 100) do
      # The four guest-access facts, each independently true/false, so every one
      # of the sixteen combinations is reachable.
      [ choose(true, false), choose(true, false), choose(true, false), choose(true, false) ]
    end.check do |(scoped, active, expired, removed)|
      valid = StreamTokenService.guest_access_valid?(
        token_scoped_to_session: scoped,
        session_active: active,
        session_expired: expired,
        guest_removed: removed
      )

      expected = scoped && active && !expired && !removed

      assert_equal expected, valid,
        "guest access is valid iff scoped AND active AND NOT expired AND NOT removed " \
        "(scoped=#{scoped}, active=#{active}, expired=#{expired}, removed=#{removed})"

      # Each required condition is individually necessary: flipping any single
      # one to its denying value must revoke authorization.
      assert_not StreamTokenService.guest_access_valid?(
        token_scoped_to_session: false, session_active: active, session_expired: expired, guest_removed: removed
      ), "a token not bound to this session must never authorize"
      assert_not StreamTokenService.guest_access_valid?(
        token_scoped_to_session: scoped, session_active: false, session_expired: expired, guest_removed: removed
      ), "an ended (non-active) session must never authorize"
      assert_not StreamTokenService.guest_access_valid?(
        token_scoped_to_session: scoped, session_active: active, session_expired: true, guest_removed: removed
      ), "an expired session must never authorize"
      assert_not StreamTokenService.guest_access_valid?(
        token_scoped_to_session: scoped, session_active: active, session_expired: expired, guest_removed: true
      ), "a removed guest must never authorize"

      # A co-listen stream is never public: the pure decision fed only the
      # guest-access fact must equal that fact (no public/token/account bypass).
      assert_equal valid,
        StreamTokenService.stream_authorized?(guest_access_valid: valid),
        "a co-listen stream is authorized only by a valid guest-derived token, never publicly"
    end
  end

  # Feature: radio-party-colisten, Property 27: Co-listen stream authorization tracks guest access validity
  test "record-based colisten_stream_authorized? serves audio iff a real derived token resolves to a guest bound to this active, unexpired session whose guest is not removed" do
    check_property(iterations: 100) do
      # Which guest-derived token the request presents, the session's lifecycle
      # state, whether its duration has elapsed, and whether the guest has been
      # removed.
      binding_kind = choose(:this_session, :other_session, :nil_token, :garbage_token)
      session_ended = choose(true, false)
      session_expired = choose(true, false)
      guest_removed = choose(true, false)

      [ binding_kind, session_ended, session_expired, guest_removed ]
    end.check do |(binding_kind, session_ended, session_expired, guest_removed)|
      reset_dataset!
      host = build_host

      # The session under test, plus a second session used to mint a token bound
      # to a *different* session for the wrong-session case.
      session = CoListenSession.create!(user: host)
      other_session = CoListenSession.create!(user: host)

      target_guest = build_guest(session)
      other_guest = build_guest(other_session)

      # Removal is persisted before deriving/using the token so the DB-backed
      # `colisten_guest_for` resolution observes the guest's live state.
      target_guest.remove! if guest_removed && binding_kind == :this_session
      other_guest.remove! if guest_removed && binding_kind == :other_session

      session.update!(state: :ended) if session_ended

      raw_token =
        case binding_kind
        when :this_session  then StreamTokenService.colisten_token_for(target_guest)
        when :other_session then StreamTokenService.colisten_token_for(other_guest)
        when :nil_token     then nil
        when :garbage_token then "not-a-valid-signed-id"
        end

      authorized = StreamTokenService.colisten_stream_authorized?(
        session: session,
        raw_token: raw_token,
        session_expired: session_expired
      )

      # A token authorizes iff it resolves to a guest bound to *this* session,
      # the session is active, it has not expired, and the guest is not removed.
      token_resolves = binding_kind.in?(%i[this_session other_session])
      token_scoped = binding_kind == :this_session
      expected =
        token_resolves && token_scoped && !session_ended && !session_expired && !guest_removed

      assert_equal expected, authorized,
        "colisten_stream_authorized? must serve audio iff a derived token resolves to a " \
        "guest bound to this active, unexpired session whose guest is not removed " \
        "(binding=#{binding_kind}, ended=#{session_ended}, expired=#{session_expired}, removed=#{guest_removed})"

      # An absent or malformed token can never authorize, regardless of session
      # or guest state.
      if binding_kind.in?(%i[nil_token garbage_token])
        assert_not authorized, "a missing or malformed co-listen token must never authorize"
      end

      # A token minted for another session must never authorize this session,
      # even when this session is perfectly live.
      if binding_kind == :other_session
        assert_not authorized, "a token bound to a different session must never authorize this one"
      end

      # The token->Guest resolution is the identity binding: a resolvable token
      # comes back as exactly the guest it was minted for.
      if binding_kind == :this_session
        assert_equal target_guest, StreamTokenService.colisten_guest_for(raw_token),
          "a derived co-listen token must resolve back to exactly its guest"
      end
    end
  end

  private

  def next_seq
    @seq += 1
  end

  # Wipe every session/guest built by prior iterations so each iteration
  # observes only the records it creates.
  def reset_dataset!
    Guest.delete_all
    CoListenSession.delete_all
    PartySession.delete_all
  end

  # A fresh Host user for a Co_Listen_Session.
  def build_host
    User.create!(email: "colisten-host-#{SecureRandom.uuid}@example.com", password: "foobar123")
  end

  # Admit a Guest to `session` with a real keyed-digest Guest_Token.
  def build_guest(session)
    session.guests.create!(
      display_name: "Guest-#{next_seq}",
      token: SecureRandom.urlsafe_base64(24)
    )
  end
end
