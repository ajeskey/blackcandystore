# frozen_string_literal: true

require "test_helper"

# Property-based test for the host-only device selection + transport control
# seam of the radio-party-colisten feature (design Property 23).
#
# AuthorizationPolicy.device_selection_authorized?(actor:, session:) and
# AuthorizationPolicy.transport_control_authorized?(actor:, session:) are the
# pure predicates the Party_Session / Co_Listen_Session controllers consult
# before selecting or changing a session's Output_Devices or issuing transport
# control (stop, pause, skip). The rule (Req 6.2, 6.5, 6.8, 7.10) is:
#
#   permitted iff the actor is the Host of the session — a full User account
#   whose id is the session's owning user_id. A Guest, any other User, or an
#   anonymous (nil) caller is always rejected, regardless of any coincidental id
#   overlap between a Guest and the owner.
#
# Each iteration builds an isolated session — a Party_Session or a
# Co_Listen_Session in a generated Session_State — then evaluates both
# predicates for a generated actor kind (host, guest, other user, nil). Because
# both predicates are pure (they read state and return a boolean, mutating
# nothing), the session's persisted state is snapshotted before and after the
# decision to confirm a rejection leaves all state unchanged (Property 23's "no
# state changes").
class HostControlAuthorityPropertyTest < ActiveSupport::TestCase
  # The actor kinds exercised against every session. Only :host is ever
  # authorized to select devices or issue transport control.
  ACTOR_KINDS = %i[host guest other nil].freeze
  AUTHORIZED_KINDS = %i[host].freeze

  setup do
    @seq = 0
    @fixture_library_ids = [ libraries(:default_library).id, libraries(:secondary_library).id ]
  end

  # Feature: radio-party-colisten, Property 23: Host-only device selection and transport control
  test "device selection and transport control are authorized iff the actor is the Host, and a rejected decision leaves the session's state unchanged" do
    check_property(iterations: 100) do
      session_kind = choose(:party, :colisten)
      actor_kind = choose(*ACTOR_KINDS)
      # A generated persisted Session_State so authority is shown to be
      # independent of the session's lifecycle position.
      state = choose("active", "ended")

      [ session_kind, actor_kind, state ]
    end.check do |(session_kind, actor_kind, state)|
      reset_dataset!
      host = create_user

      session = build_session(session_kind, host, state)
      actor = build_actor(actor_kind, host)

      expected = AUTHORIZED_KINDS.include?(actor_kind)
      before = session.attributes

      device_permitted = AuthorizationPolicy.device_selection_authorized?(actor: actor, session: session)
      transport_permitted = AuthorizationPolicy.transport_control_authorized?(actor: actor, session: session)

      assert_equal expected, device_permitted,
        "#{actor_kind} selecting devices on a #{session_kind} session should be " \
        "#{expected ? "permitted" : "rejected"}"
      assert_equal expected, transport_permitted,
        "#{actor_kind} issuing transport control on a #{session_kind} session should be " \
        "#{expected ? "permitted" : "rejected"}"

      # A pure decision never mutates the session — a rejection (or a grant)
      # leaves it exactly as it was (Property 23's "no state changes").
      session.reload
      assert_equal before, session.attributes,
        "evaluating host authority must not change the #{session_kind} session's state"

      # A Guest is never a User, so id overlap with the Host grants no authority:
      # even against a session whose user_id coincides with the Guest's id, a
      # Guest is still rejected for both device selection and transport control.
      if actor_kind == :guest
        coincident = build_session(session_kind, host, state)
        coincident.user_id = actor.id
        assert_not AuthorizationPolicy.device_selection_authorized?(actor: actor, session: coincident),
          "a Guest is never authorized to select devices, even when its id coincides with the owner_id"
        assert_not AuthorizationPolicy.transport_control_authorized?(actor: actor, session: coincident),
          "a Guest is never authorized to issue transport control, even when its id coincides with the owner_id"
      end
    end
  end

  private

  def next_seq
    @seq += 1
  end

  # Wipe all feature session/guest records so each iteration observes only the
  # session it builds.
  def reset_dataset!
    Guest.delete_all
    PartySession.delete_all
    CoListenSession.delete_all
  end

  def create_user
    User.create!(email: "host-ctrl-#{SecureRandom.uuid}@example.com", password: "foobar123")
  end

  # Build the actor for the given kind. :host is the session's owning User;
  # :other is a distinct User (never the Host); :guest is a Guest admitted to a
  # throwaway active session (never a User); :nil is an anonymous caller.
  def build_actor(actor_kind, host)
    case actor_kind
    when :host then host
    when :other then create_user
    when :guest
      Guest.create!(sessionable: build_session(:party, create_user, "active"), token: "guest-#{next_seq}")
    when :nil then nil
    end
  end

  # Build a persisted session of the given kind in the given Session_State. An
  # empty shared-library set is a valid subset of any Host's authorization.
  def build_session(session_kind, host, state)
    case session_kind
    when :party then PartySession.create!(user: host, state: state)
    when :colisten then CoListenSession.create!(user: host, state: state)
    end
  end
end
