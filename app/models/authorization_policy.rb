# frozen_string_literal: true

# AuthorizationPolicy is the pure, side-effect-free decision core for the
# authority rules that govern who may act on a Radio_Station, a Party_Session or
# Co_Listen_Session, and the entries of their Shared_Playlist. It complements
# BroadcastLifecycle (which owns the lifecycle *transition* + concurrency rules)
# by collecting the remaining authority predicates the controllers and service
# objects consult before performing a mutation.
#
# Three distinct authority rules live here, each modeled as a boolean predicate
# over already-loaded state so they can be property-tested in isolation without
# touching the database or the Broadcaster:
#
# 1. **Mutation / lifecycle authority** (Req 1.8, 10.3, 10.9; Property 4) — a
#    create/modify/delete or start/stop/activate/deactivate is permitted iff the
#    actor is the owning User/Host or an Admin. This reuses
#    `BroadcastLifecycle.authorized?` rather than duplicating the owner/admin
#    check, keeping a single definition of "owner or admin".
#
# 2. **Shared_Playlist entry mutation authority** (Req 6.6; Property 22) —
#    removing or reordering an entry is permitted iff the actor is the Host or
#    the Guest that added that specific entry. A Guest may never touch another
#    participant's entry.
#
# 3. **Host-only device selection + transport control** (Req 6.2, 6.5, 6.8,
#    7.10; Property 23) — selecting/changing a session's Output_Devices and
#    issuing transport control (stop, pause, skip) is permitted iff the actor is
#    the Host. Guests (and any non-Host) are always rejected.
#
# Every method reads state and returns a boolean; none mutates a record, so a
# rejection leaves all state unchanged by construction.
module AuthorizationPolicy
  module_function

  # Mutation / lifecycle authority (Req 1.8, 10.3, 10.9; Property 4). Permitted
  # iff the actor is the owning User/Host (`actor.id == owner_id`) or an Admin.
  # Delegates to BroadcastLifecycle so the owner-or-admin rule has a single
  # definition; a Guest or anonymous caller is never a User and so is rejected.
  #
  # @param actor [Object] the caller (User, Guest, or nil)
  # @param owner_id [Integer] the subject's owning `user_id`
  # @return [Boolean]
  def mutation_authorized?(actor, owner_id)
    BroadcastLifecycle.authorized?(actor, owner_id)
  end

  # Shared_Playlist entry mutation authority (Req 6.6; Property 22). Removing or
  # reordering `entry` within `session`'s Shared_Playlist is permitted iff the
  # actor is the Host of the session, or the actor is the Guest that added that
  # specific entry. Any other actor — including a Guest attempting another
  # participant's entry — is rejected.
  #
  # @param actor [Object] the caller (User Host or Guest)
  # @param entry [SharedPlaylistEntry] the entry being removed/reordered
  # @param session [PartySession, CoListenSession] the session that owns the entry
  # @return [Boolean]
  def entry_mutation_authorized?(actor:, entry:, session:)
    return true if host?(actor, session)

    guest_owns_entry?(actor, entry)
  end

  # Host-only device selection authority (Req 6.2, 6.5; Property 23). Selecting
  # or changing a session's Output_Devices is permitted iff the actor is the
  # Host. A Guest — or any non-Host — is rejected.
  #
  # @param actor [Object] the caller (User Host or Guest)
  # @param session [PartySession, CoListenSession] the session
  # @return [Boolean]
  def device_selection_authorized?(actor:, session:)
    host?(actor, session)
  end

  # Host-only transport control authority (Req 6.8, 7.10; Property 23). Issuing
  # transport control (stop, pause, skip) over a session's playback or
  # Shared_Stream is permitted iff the actor is the Host. A Guest — or any
  # non-Host — is rejected.
  #
  # @param actor [Object] the caller (User Host or Guest)
  # @param session [PartySession, CoListenSession] the session
  # @return [Boolean]
  def transport_control_authorized?(actor:, session:)
    host?(actor, session)
  end

  # Whether `actor` is the Host of `session`: a full User account whose id is the
  # session's owning `user_id`. A Guest is not a User, so it can never be the
  # Host regardless of any coincidental id overlap.
  #
  # @param actor [Object] the caller
  # @param session [PartySession, CoListenSession] the session
  # @return [Boolean]
  def host?(actor, session)
    return false unless actor.is_a?(User)
    return false if session.nil?

    actor.id == session.user_id
  end

  # Whether `actor` is the Guest that added `entry`. True only when the actor is
  # a Guest, the entry was added by a Guest (not the Host), and the ids match.
  #
  # @param actor [Object] the caller
  # @param entry [SharedPlaylistEntry] the entry being acted on
  # @return [Boolean]
  def guest_owns_entry?(actor, entry)
    return false unless actor.is_a?(Guest)
    return false if entry.nil? || entry.added_by_guest_id.blank?

    actor.id == entry.added_by_guest_id
  end
end
