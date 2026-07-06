# frozen_string_literal: true

require "securerandom"

# GuestAccessResolver is the pure, mostly side-effect-free domain seam for the
# Guest/shared-session access model shared by Party_Sessions and
# Co_Listen_Sessions. It complements AuthorizationPolicy (owner/host/entry
# authority) and StreamTokenService (stream credential mechanics) by owning the
# decisions that govern *whether a Guest may join, and whether an admitted
# Guest's request is still valid*.
#
# It is deliberately named `GuestAccessResolver` (not `GuestAccess`) so it does
# not clash with the `GuestAccess` controller concern wired in a later task
# (task 8.1); that concern resolves the Bearer credential off the request and
# then delegates the actual decisions to this seam.
#
# The rules modeled here, each as a pure predicate over already-loaded state so
# they can be property-tested in isolation:
#
# 1. **Admission** (Req 5.1, 5.11; Property 14) — a Guest is admitted and issued
#    a Guest_Token iff the backing Access_Grant is `usable?` (active and not
#    expired) AND the session's current guest count is below `max_guests`.
#    Otherwise admission is refused: an unusable grant is an authorization
#    error, a full session is a capacity response, and *no* Guest record or
#    token is created.
#
# 2. **Library scoping with existence-hiding** (Req 5.3, 5.4, 5.5, 8.2, 8.6;
#    Property 15) — a Guest may read/add a Song or Library iff it belongs to a
#    Library the session shares. The predicate returns the *same* negative
#    result for out-of-scope content as for non-existent content, giving the
#    controller a single existence-hiding basis for its not-found response.
#
# 3. **Live-state gating** (Req 5.6, 5.8, 8.4, 12.2; Property 16) — a request
#    bearing a Guest_Token is authorized iff the session is `active`, the
#    session has not expired, and the Guest has not been removed. Any one
#    failing condition rejects, so a previously admitted Guest loses access the
#    moment the session ends/expires or it is removed.
#
# 4. **Terminal revocation blocks only new joins** (Req 4.6, 8.5; Property 17) —
#    admission consults the backing grant's `usable?`, so a revoked grant
#    refuses new joins; live-state gating (rule 3) does *not* consult
#    revocation, so Guests admitted before revocation retain access until the
#    session expires or ends. (The revoke action itself lives in
#    ShareLinkService#revoke; revocation is terminal on AccessGrant.)
#
# 5. **Token to Guest identity binding** (Req 5.13; Property 18) — a presented
#    Guest_Token resolves to exactly one Guest via its keyed digest, and
#    distinct tokens resolve to distinct Guests, so quota accounting and removal
#    permissions always attribute a request to a single Guest.
#
# 6. **Retained-playlist host-only access** (Req 12.2, 12.3; Property 30) —
#    after a session ends or expires its Shared_Playlist stays readable by the
#    Host and is rejected for every Guest request.
#
# Only #admit performs a write (it creates the admitted Guest); every other
# method reads state and returns a boolean or a resolved record, so a rejection
# leaves all state unchanged by construction.
module GuestAccessResolver
  # Bytes of cryptographic randomness in a generated Guest_Token secret.
  # 32 bytes = 256 bits, matching the other keyed secrets in the feature.
  GUEST_TOKEN_SECRET_BYTES = 32

  # Admission refused because the backing Access_Grant is not usable (revoked or
  # expired) — surfaced by the controller as an authorization error (Req 5.1).
  ERROR_UNAUTHORIZED = :unauthorized

  # Admission refused because the session is already at `max_guests` — surfaced
  # by the controller as a capacity response (Req 5.11).
  ERROR_AT_CAPACITY = :at_capacity

  # The outcome of an admission attempt. `ok?` reports whether a Guest was
  # admitted; on success `guest` is the persisted Guest and `token` is its
  # plaintext Guest_Token (returned exactly once, never persisted in plaintext).
  # On refusal `error` is `:unauthorized` or `:at_capacity` and both `guest` and
  # `token` are nil — no record or token was created (Property 14).
  Admission = Struct.new(:ok, :error, :guest, :token, keyword_init: true) do
    def ok?
      ok
    end

    def denied?
      !ok
    end
  end

  module_function

  # --- Admission (Req 5.1, 5.11; Property 14) ---------------------------------

  # Pure admission decision: a Guest may be admitted iff the backing grant is
  # usable AND the session has capacity below `max_guests` (Property 14). A nil
  # `max_guests` means unbounded.
  #
  # @param grant_usable [Boolean] the backing Access_Grant's `usable?`
  # @param current_guest_count [Integer] the session's current guest count
  # @param max_guests [Integer, nil] the configured maximum (nil = unbounded)
  # @return [Boolean]
  def admissible?(grant_usable:, current_guest_count:, max_guests:)
    return false unless grant_usable

    capacity_available?(current_guest_count: current_guest_count, max_guests: max_guests)
  end

  # Whether the session can admit one more Guest without exceeding `max_guests`
  # (Req 5.11). A nil `max_guests` means unbounded.
  #
  # @param current_guest_count [Integer]
  # @param max_guests [Integer, nil]
  # @return [Boolean]
  def capacity_available?(current_guest_count:, max_guests:)
    return true if max_guests.nil?

    current_guest_count.to_i < max_guests
  end

  # The pure reason an admission would be refused, or nil when it would succeed
  # (Property 14). An unusable grant is reported first as `:unauthorized`
  # (Req 5.1); a usable grant at the guest maximum is `:at_capacity` (Req 5.11).
  #
  # @param grant_usable [Boolean]
  # @param current_guest_count [Integer]
  # @param max_guests [Integer, nil]
  # @return [Symbol, nil]
  def admission_denial_reason(grant_usable:, current_guest_count:, max_guests:)
    return ERROR_UNAUTHORIZED unless grant_usable
    return ERROR_AT_CAPACITY unless capacity_available?(current_guest_count: current_guest_count, max_guests: max_guests)

    nil
  end

  # Whether a *new* join is allowed against `grant` (Req 4.6, 8.5; Property 17).
  # A revoked or expired grant is not usable, so revocation terminally blocks new
  # joins — while leaving already-admitted Guests untouched (they are gated by
  # `request_authorized?`, which never consults revocation).
  #
  # @param grant [AccessGrant, nil] the backing grant
  # @return [Boolean]
  def new_join_allowed?(grant)
    grant.respond_to?(:usable?) && grant.usable? == true
  end

  # Admit a Guest into `session` through the backing `grant`, issuing a bound
  # Guest_Token (Req 5.1, 5.13; Property 14, Property 18). Returns an Admission:
  # on success it carries the persisted Guest and its plaintext token (readable
  # once); on refusal it carries `:unauthorized` (unusable grant) or
  # `:at_capacity` (guest maximum reached) and creates neither a Guest nor a
  # token. Capacity is measured as the count of not-removed Guests.
  #
  # @param session [PartySession, CoListenSession] the session to admit into
  # @param grant [AccessGrant] the backing Access_Grant of the opened Share_Link
  # @param display_name [String, nil] the Guest's optional display name (Req 5.12)
  # @param now [Time] the admission time
  # @param raw_token [String] the plaintext Guest_Token (defaults to a fresh secret)
  # @return [Admission]
  def admit(session:, grant:, display_name: nil, now: Time.current, raw_token: generate_token)
    reason = admission_denial_reason(
      grant_usable: new_join_allowed?(grant),
      current_guest_count: current_guest_count(session),
      max_guests: session.max_guests
    )
    return Admission.new(ok: false, error: reason, guest: nil, token: nil) if reason

    guest = session.guests.new(display_name: display_name.presence, admitted_at: now, add_count: 0)
    guest.token = raw_token
    guest.save!

    Admission.new(ok: true, error: nil, guest: guest, token: raw_token)
  end

  # The session's current guest count for capacity accounting: Guests that have
  # been admitted and not removed. A removed Guest frees its slot (Req 5.8, 5.11).
  #
  # @param session [PartySession, CoListenSession]
  # @return [Integer]
  def current_guest_count(session)
    session.guests.where(removed_at: nil).count
  end

  # --- Token to Guest identity binding (Req 5.13; Property 18) ----------------

  # Resolve a presented plaintext Guest_Token to the single Guest it is bound to
  # (Property 18), via the keyed-digest lookup on Guest. Returns nil when no
  # Guest matches. When `session` is given, the resolved Guest must belong to it
  # (token to Guest to session), so a token from another session never resolves
  # here.
  #
  # @param raw_token [String, nil] the presented plaintext Guest_Token
  # @param session [PartySession, CoListenSession, nil] optional scope check
  # @return [Guest, nil]
  def resolve_guest(raw_token, session: nil)
    guest = Guest.find_by_token(raw_token)
    return if guest.nil?
    return if session && guest.sessionable != session

    guest
  end

  # --- Library scoping with existence-hiding (Property 15) --------------------

  # Whether content in Library `content_library_id` is within the session's
  # shared scope (Req 5.3, 8.2). The predicate returns false both for content in
  # a Library the session does not share and for content that does not exist
  # (a nil library id), giving the caller a single existence-hiding basis: an
  # out-of-scope target is indistinguishable from a missing one (Req 5.4, 5.5,
  # 8.6; Property 15). It never widens access beyond the shared libraries.
  #
  # @param content_library_id [Integer, nil] the Library the target belongs to
  # @param shared_library_ids [Array<Integer>] the session's shared libraries
  # @return [Boolean]
  def content_in_scope?(content_library_id:, shared_library_ids:)
    return false if content_library_id.nil?

    Array(shared_library_ids).map(&:to_i).include?(content_library_id.to_i)
  end

  # Record-based convenience: whether `content_library_id` is within `session`'s
  # shared libraries (Property 15). A false result is the existence-hiding
  # basis the controller turns into a uniform not-found response.
  #
  # @param session [PartySession, CoListenSession]
  # @param content_library_id [Integer, nil]
  # @return [Boolean]
  def content_accessible?(session:, content_library_id:)
    content_in_scope?(
      content_library_id: content_library_id,
      shared_library_ids: session.shared_library_ids
    )
  end

  # --- Live-state gating (Req 5.6, 5.8, 8.4, 12.2; Property 16) ---------------

  # Pure live-state gate for a request bearing a Guest_Token (Property 16): the
  # request is authorized iff the session is active, the session has not expired,
  # and the Guest has not been removed. Any single failing condition rejects.
  #
  # @param session_active [Boolean] Session_State is `active` (not ended)
  # @param session_expired [Boolean] the Session_Duration has elapsed
  # @param guest_removed [Boolean] the Host has removed this Guest
  # @return [Boolean]
  def request_authorized?(session_active:, session_expired:, guest_removed:)
    session_active && !session_expired && !guest_removed
  end

  # Record-based convenience for the live-state gate (Property 16): composes the
  # session's `active?`, its computed expiry, and the Guest's `removed?` into the
  # pure `request_authorized?` decision. Rejects when either record is nil.
  #
  # @param session [PartySession, CoListenSession]
  # @param guest [Guest]
  # @param now [Time] the reference time for the expiry check
  # @return [Boolean]
  def access_valid?(session:, guest:, now: Time.current)
    return false if session.nil? || guest.nil?

    request_authorized?(
      session_active: session.respond_to?(:active?) && session.active?,
      session_expired: session_expired?(session, now: now),
      guest_removed: guest.removed?
    )
  end

  # Whether `session` has expired at `now` (Req 8.4). Expiry is read from the
  # session's backing Access_Grant expiration (the Session_Duration to
  # `expires_at` mapping owned by ShareLinkService): a perpetual session has no
  # expiration and never expires. Independent of revocation, so an expired
  # session rejects even already-admitted Guests while a revoked-but-unexpired
  # session does not (Property 16, Property 17).
  #
  # @param session [PartySession, CoListenSession]
  # @param now [Time]
  # @return [Boolean]
  def session_expired?(session, now: Time.current)
    expires_at = session_expires_at(session)
    expires_at.present? && expires_at <= now
  end

  # The representative expiration for `session`: the earliest `expires_at` across
  # its backing grants, or nil when none is set (perpetual). All grants for a
  # session are generated together with the same expiration, so the earliest is
  # authoritative; taking the minimum is conservative if they ever differ.
  #
  # @param session [PartySession, CoListenSession]
  # @return [Time, nil]
  def session_expires_at(session)
    grant_ids = session.share_links.select(:access_grant_id)
    AccessGrant.where(id: grant_ids).minimum(:expires_at)
  end

  # --- Retained-playlist host-only access (Req 12.2, 12.3; Property 30) -------

  # Whether `actor` may read `session`'s Shared_Playlist (Property 30). The Host
  # may always read it — including after teardown, for review (Req 12.3). A Guest
  # may read it only while its access is live (session active, not expired, Guest
  # not removed), so once the session ends or expires every Guest request is
  # rejected (Req 12.2) while the retained playlist stays host-only.
  #
  # @param actor [Object] the caller (User Host or Guest)
  # @param session [PartySession, CoListenSession]
  # @param guest [Guest, nil] the Guest when the actor is not the Host
  # @param now [Time] the reference time for the live-state check
  # @return [Boolean]
  def playlist_readable?(actor:, session:, guest: nil, now: Time.current)
    return true if AuthorizationPolicy.host?(actor, session)

    effective_guest = guest || (actor if actor.is_a?(Guest))
    return false if effective_guest.nil?

    access_valid?(session: session, guest: effective_guest, now: now)
  end

  # A fresh URL-safe plaintext Guest_Token secret (Req 5.13, 8.7). Never
  # persisted; only its keyed digest is stored on the Guest.
  #
  # @return [String]
  def generate_token
    SecureRandom.urlsafe_base64(GUEST_TOKEN_SECRET_BYTES)
  end
end
