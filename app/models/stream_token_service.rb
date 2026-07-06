# frozen_string_literal: true

require "securerandom"

# StreamTokenService owns the credential mechanics and the pure authorization
# decision for tuning into a Shared_Stream. It has two token families and one
# decision seam:
#
# 1. **Radio Stream_Tokens** (Req 11.3, 11.5) — a revocable/rotatable secret
#    persisted only as a keyed digest on the station's `StreamToken`, mirroring
#    `AccessGrant`'s keyed-digest + constant-time verify. Issuance mints a fresh
#    secret; rotation replaces it so any previously distributed URL stops
#    authorizing; revocation flips the token to `revoked` (terminal). The
#    plaintext is returned in-memory exactly once (via `StreamToken#token`) so it
#    can be embedded into the Stream_Endpoint URL, and is never persisted.
#
# 2. **Co-listen guest-derived Stream_Tokens** (Req 11.8, 11.9) — NOT stored in
#    `stream_tokens`. Each participant's token is a purpose-scoped Rails
#    `signed_id` minted from that participant's `Guest` record under the
#    `:colisten_stream` purpose. Because it resolves back to the exact Guest, it
#    is inherently scoped to that Guest's session and its shared libraries, and
#    it stops authorizing exactly when the Guest's access ends (session ended,
#    expired, or Guest removed). A co-listen stream is never public.
#
# 3. **A pure `stream_authorized?` decision** (Property 9, Property 27) — a
#    side-effect-free disjunction over the four ways a Stream_Endpoint request
#    can be authorized: `public` station, a valid radio Stream_Token, a valid
#    authorized account, or a valid guest-derived co-listen token. Callers
#    compute each fact (via the helpers below or the existing Authentication
#    path) and hand the booleans to the decision, keeping it deterministic and
#    directly property-testable without any I/O.
module StreamTokenService
  # Purpose namespace for the per-participant co-listen Stream_Token derived
  # from a Guest's `signed_id`. Scoping to the session + shared libraries is
  # inherent in the Guest binding the signed id resolves to (Req 11.8, 11.9).
  COLISTEN_STREAM_PURPOSE = :colisten_stream

  # Bytes of cryptographic randomness in a generated radio Stream_Token secret.
  # 32 bytes = 256 bits, matching the strength of the other keyed secrets.
  STREAM_TOKEN_SECRET_BYTES = 32

  module_function

  # --- Radio Stream_Token lifecycle (keyed digest, Req 11.5) ------------------

  # Issues a fresh Stream_Token for `radio_station`, persisting only its keyed
  # digest and returning the created `StreamToken` with its plaintext available
  # in-memory exactly once (via `#token`). Any existing token is discarded so a
  # station always has at most one active Stream_Token.
  #
  # @param radio_station [RadioStation] the station to issue a token for
  # @param raw_token [String] the plaintext secret (defaults to a fresh secret)
  # @return [StreamToken] the persisted token, plaintext readable once via #token
  def issue_radio_token(radio_station, raw_token: generate_secret)
    radio_station.stream_token&.destroy
    radio_station.reload if radio_station.persisted?

    token = radio_station.build_stream_token
    token.token = raw_token
    token.save!
    token
  end

  # Rotates a station's Stream_Token: mints a new secret so any previously
  # distributed Stream_Endpoint URL no longer authorizes (Req 11.5). Equivalent
  # to re-issuing.
  #
  # @param radio_station [RadioStation] the station whose token to rotate
  # @param raw_token [String] the plaintext secret (defaults to a fresh secret)
  # @return [StreamToken] the new token, plaintext readable once via #token
  def rotate_radio_token(radio_station, raw_token: generate_secret)
    issue_radio_token(radio_station, raw_token: raw_token)
  end

  # Revokes a station's Stream_Token so it no longer authorizes access
  # (terminal, Req 11.5). Idempotent; a no-op when the station has no token.
  #
  # @param radio_station [RadioStation] the station whose token to revoke
  # @return [StreamToken, nil] the revoked token, or nil when none existed
  def revoke_radio_token(radio_station)
    token = radio_station.stream_token
    token&.revoke!
    token
  end

  # Constant-time validity of a presented plaintext radio Stream_Token: true iff
  # the station has a token that is still usable (active, not revoked) AND the
  # presented plaintext authenticates against its stored keyed digest. Mirrors
  # `AccessGrant.authenticate_token` (Req 11.3, 11.5, Property 10). A rotated or
  # revoked token — or a never-generated one — never validates.
  #
  # @param radio_station [RadioStation, nil] the station to validate against
  # @param raw_token [String, nil] the presented plaintext token
  # @return [Boolean]
  def valid_radio_token?(radio_station, raw_token)
    token = radio_station&.stream_token
    return false if token.blank?

    token.usable? && token.authenticate_token(raw_token)
  end

  # --- Co-listen guest-derived Stream_Token (signed id, Req 11.8/11.9) --------

  # Derives the per-participant co-listen Stream_Token for `guest`: a
  # purpose-scoped Rails signed id that resolves back to exactly this Guest.
  # Scoping to the session and its shared libraries is inherent in the Guest
  # binding (Req 11.8). By default the signed id carries no independent
  # expiration so it stops authorizing *exactly* when the Guest's access ends
  # (session ended/expired or Guest removed), rather than on an unrelated clock
  # (Req 11.9, Property 27); a caller may still pass `expires_in` to add an
  # upper bound.
  #
  # @param guest [Guest] the admitted participant
  # @param expires_in [ActiveSupport::Duration, nil] optional upper bound
  # @return [String] the signed co-listen Stream_Token
  def colisten_token_for(guest, expires_in: nil)
    guest.signed_id(purpose: COLISTEN_STREAM_PURPOSE, expires_in: expires_in)
  end

  # Resolves a presented co-listen Stream_Token back to its `Guest`, or nil when
  # the token is blank, malformed, expired, or signed for another purpose. This
  # is only the token→Guest resolution; the caller still evaluates the Guest's
  # live access via `guest_access_valid?`.
  #
  # @param raw_token [String, nil] the presented signed token
  # @return [Guest, nil]
  def colisten_guest_for(raw_token)
    return if raw_token.blank?

    Guest.find_signed(raw_token, purpose: COLISTEN_STREAM_PURPOSE)
  end

  # --- Pure authorization decision (Property 9, Property 27) ------------------

  # The pure Stream_Endpoint authorization decision: audio is served iff at
  # least one authorization path holds. Side-effect free and deterministic in
  # its inputs so it can be property-tested directly.
  #
  # Radio (Property 9): `public_stream` OR `stream_token_valid` OR
  # `account_authorized`. Co-listen (Property 27): only `guest_access_valid`
  # (a co-listen stream is never public and has no radio Stream_Token/account
  # path). Callers pass only the facts relevant to the stream kind; every unset
  # fact defaults to false, so the "no valid credential" case rejects.
  #
  # @param public_stream [Boolean] station Stream_Visibility is `public`
  # @param stream_token_valid [Boolean] a usable radio Stream_Token matched
  # @param account_authorized [Boolean] an authorized account credential present
  # @param guest_access_valid [Boolean] a live guest-derived co-listen token
  # @return [Boolean]
  def stream_authorized?(public_stream: false, stream_token_valid: false, account_authorized: false, guest_access_valid: false)
    public_stream || stream_token_valid || account_authorized || guest_access_valid
  end

  # The pure predicate behind the guest-derived co-listen case (Req 11.8, 11.9,
  # Property 27): a co-listen Stream_Token authorizes iff it is bound to this
  # session (token→Guest→session), the session is still active, the session has
  # not expired, and the Guest has not been removed. Any single failing
  # condition denies, so the token stops authorizing exactly when the Guest's
  # access ends. Side-effect free.
  #
  # @param token_scoped_to_session [Boolean] resolved Guest belongs to this session
  # @param session_active [Boolean] Session_State is `active` (not ended/torn down)
  # @param session_expired [Boolean] the Session_Duration has elapsed
  # @param guest_removed [Boolean] the Host has removed this Guest
  # @return [Boolean]
  def guest_access_valid?(token_scoped_to_session:, session_active:, session_expired:, guest_removed:)
    token_scoped_to_session && session_active && !session_expired && !guest_removed
  end

  # Record-based convenience for a Co_Listen_Session Stream_Endpoint request
  # (used by the stream endpoint controller in a later task): resolves the
  # presented signed token to a Guest and feeds `guest_access_valid?` into the
  # pure `stream_authorized?` decision. `session_expired` is supplied by the
  # caller (the Session_Duration → expiry mapping lives with the session
  # lifecycle), keeping this method free of duration arithmetic.
  #
  # @param session [CoListenSession] the co-listen session being tuned into
  # @param raw_token [String, nil] the presented signed co-listen token
  # @param session_expired [Boolean] whether the session's duration has elapsed
  # @return [Boolean]
  def colisten_stream_authorized?(session:, raw_token:, session_expired: false)
    guest = colisten_guest_for(raw_token)
    return false if guest.blank?

    stream_authorized?(
      guest_access_valid: guest_access_valid?(
        token_scoped_to_session: guest.sessionable == session,
        session_active: session.respond_to?(:active?) && session.active?,
        session_expired: session_expired,
        guest_removed: guest.removed?
      )
    )
  end

  # Record-based convenience for a Radio_Station Stream_Endpoint request:
  # composes the visibility, radio-token, and account facts into the pure
  # decision. `account_authorized` is supplied by the caller (resolved through
  # the existing Authentication path), keeping this method free of session/auth
  # plumbing.
  #
  # @param radio_station [RadioStation] the station being tuned into
  # @param raw_token [String, nil] the presented radio Stream_Token
  # @param account_authorized [Boolean] an authorized account credential present
  # @return [Boolean]
  def radio_stream_authorized?(radio_station:, raw_token: nil, account_authorized: false)
    stream_authorized?(
      public_stream: radio_station.respond_to?(:visibility_public?) && radio_station.visibility_public?,
      stream_token_valid: valid_radio_token?(radio_station, raw_token),
      account_authorized: account_authorized
    )
  end

  # A fresh URL-safe plaintext Stream_Token secret (Req 11.5). Never persisted;
  # only its keyed digest is stored on the `StreamToken`.
  #
  # @return [String]
  def generate_secret
    SecureRandom.urlsafe_base64(STREAM_TOKEN_SECRET_BYTES)
  end
end
