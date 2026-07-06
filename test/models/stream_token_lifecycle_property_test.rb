# frozen_string_literal: true

require "test_helper"

# Property-based test for the token keyed-digest lifecycle of the
# radio-party-colisten feature (design Property 10; Req 8.7, 11.5).
#
# It exercises the two credential families that authorize tuning into a
# Shared_Stream or joining a shared session — the radio Stream_Token (via
# StreamToken / StreamTokenService) and the Share_Link token (via
# AccessGrant / ShareLinkService) — directly against the pure model + service
# seams, with no Broadcaster or controller involved.
#
# For every generated token the property asserts, end to end, that:
#   * only the keyed HMAC digest is persisted; the plaintext is never written
#     to any column and is unavailable after reload;
#   * the stored digest authenticates the exact plaintext (and rejects a
#     near-miss) through the model's constant-time comparison;
#   * a rotated Stream_Token and a revoked Stream_Token / Share_Link no longer
#     authorize; and
#   * a token that was never generated never matches any stored digest.
#
# Each iteration works on freshly-built feature records (see reset_feature_data!)
# so digests, rotation, and revocation are observed in isolation. Token
# plaintexts are role-prefixed so the "initial", "rotated", "grant", and
# "never generated" secrets are guaranteed distinct while their bodies remain
# randomly generated (and therefore shrinkable).
class StreamTokenLifecyclePropertyTest < ActiveSupport::TestCase
  # Feature: radio-party-colisten, Property 10: Tokens are persisted only as keyed digests and honor their lifecycle
  test "generated Stream_Tokens and Share_Link tokens persist only their keyed digest, authenticate the plaintext via constant-time comparison, stop authorizing once rotated or revoked, and never match a token that was never generated" do
    check_property(iterations: 100) do
      # Four independently generated, non-blank token bodies: the initial radio
      # Stream_Token, its rotation, the Share_Link (AccessGrant) token, and a
      # token that is never generated/persisted.
      [
        sized(range(1, 40)) { string(:alnum) },
        sized(range(1, 40)) { string(:alnum) },
        sized(range(1, 40)) { string(:alnum) },
        sized(range(1, 40)) { string(:alnum) }
      ]
    end.check do |(init_body, rotated_body, grant_body, never_body)|
      reset_feature_data!

      # Role prefixes guarantee the four secrets are distinct and non-blank.
      init_secret = "st-init-#{init_body}"
      rotated_secret = "st-rot-#{rotated_body}"
      grant_secret = "ag-#{grant_body}"
      never_secret = "never-#{never_body}"

      assert_stream_token_lifecycle(init_secret, rotated_secret, never_secret)
      assert_access_grant_lifecycle(grant_secret, never_secret)
      assert_share_link_service_lifecycle(never_secret)
    end
  end

  private

  # --- Radio Stream_Token lifecycle (Req 11.5) -----------------------------

  def assert_stream_token_lifecycle(init_secret, rotated_secret, never_secret)
    station = build_station

    # Issue: only the keyed digest is persisted; the plaintext is never stored.
    token = StreamTokenService.issue_radio_token(station, raw_token: init_secret)
    assert_digest_only_persistence(StreamToken.find(token.id), :token_digest, StreamToken, init_secret)

    # The stored digest authenticates the exact plaintext and rejects both a
    # near-miss and a never-generated token (constant-time comparison).
    assert token.authenticate_token(init_secret), "issued token must authenticate its plaintext"
    assert_not token.authenticate_token("#{init_secret}x"), "a near-miss plaintext must not authenticate"
    assert_not token.authenticate_token(never_secret), "a never-generated token must not authenticate"
    assert_equal token, StreamToken.find_by_token(init_secret), "keyed-digest lookup must find the issued token"
    assert_nil StreamToken.find_by_token(never_secret), "a never-generated token must not resolve to any token"

    station.reload
    assert StreamTokenService.valid_radio_token?(station, init_secret), "issued token must authorize"
    assert_not StreamTokenService.valid_radio_token?(station, never_secret), "never-generated token must not authorize"

    # Rotate: the previously distributed secret no longer authorizes; the new
    # secret does, and is likewise persisted only as a keyed digest.
    rotated = StreamTokenService.rotate_radio_token(station, raw_token: rotated_secret)
    station.reload
    assert_not StreamTokenService.valid_radio_token?(station, init_secret), "a rotated-out token must no longer authorize"
    assert StreamTokenService.valid_radio_token?(station, rotated_secret), "the rotated-in token must authorize"
    assert_nil StreamToken.find_by_token(init_secret), "a rotated-out token must not resolve"
    assert_digest_only_persistence(StreamToken.find(rotated.id), :token_digest, StreamToken, rotated_secret)

    # Revoke: revocation is terminal, so even the matching current secret stops
    # authorizing while its digest still matches.
    StreamTokenService.revoke_radio_token(station)
    station.reload
    assert_not StreamTokenService.valid_radio_token?(station, rotated_secret), "a revoked token must no longer authorize"
    assert station.stream_token.authenticate_token(rotated_secret),
      "revocation leaves the digest intact; only usability changes"
    assert_not station.stream_token.usable?, "a revoked token is not usable"
  end

  # --- Share_Link / AccessGrant lifecycle (Req 8.7) ------------------------

  def assert_access_grant_lifecycle(grant_secret, never_secret)
    grant = AccessGrant.new(library: default_library, status: :active)
    grant.token = grant_secret
    grant.save!

    assert_digest_only_persistence(AccessGrant.find(grant.id), :token_digest, AccessGrant, grant_secret)

    assert grant.authenticate_token(grant_secret), "grant must authenticate its plaintext"
    assert_not grant.authenticate_token("#{grant_secret}x"), "a near-miss plaintext must not authenticate"
    assert_not grant.authenticate_token(never_secret), "a never-generated token must not authenticate"
    assert_equal grant, AccessGrant.find_by_token(grant_secret), "keyed-digest lookup must find the grant"
    assert_nil AccessGrant.find_by_token(never_secret), "a never-generated token must not resolve to any grant"
    assert grant.usable?, "an active, unexpired grant is usable"

    # Revocation is terminal: the grant stops authorizing while its digest match
    # is preserved.
    grant.update!(status: :revoked)
    assert grant.reload.authenticate_token(grant_secret), "revocation leaves the digest intact"
    assert_not grant.usable?, "a revoked grant no longer authorizes"
  end

  # ShareLinkService mints one AccessGrant-backed Share_Link per shared library
  # and revokes them to block new joins; the plaintext is exposed in memory once
  # and never persisted, and revocation makes the backing grant unusable.
  def assert_share_link_service_lifecycle(never_secret)
    session = PartySession.create!(user: host, shared_library_ids: [ default_library.id ])

    links = ShareLinkService.generate(session)
    assert_equal 1, links.length, "one Share_Link is generated per shared library"

    link = links.first
    plaintext = link.access_grant.token
    assert plaintext.present?, "the backing grant plaintext is available in memory exactly once"

    grant = AccessGrant.find(link.access_grant_id)
    assert_digest_only_persistence(grant, :token_digest, AccessGrant, plaintext)
    assert_nil AccessGrant.find_by_token(never_secret), "a never-generated token never matches a Share_Link grant"
    assert grant.usable?, "a freshly generated Share_Link grant is usable"

    revoked_count = ShareLinkService.revoke(session)
    assert_equal 1, revoked_count, "revoke transitions the backing grant"
    assert_not grant.reload.usable?, "a revoked Share_Link grant no longer authorizes new joins"
  end

  # --- Shared assertions / builders ----------------------------------------

  # Asserts that `record` persists only the keyed digest of `secret`: the digest
  # column equals the model's keyed digest of the plaintext, no persisted column
  # contains the plaintext, and the in-memory plaintext is gone after reload.
  def assert_digest_only_persistence(record, digest_attribute, model, secret)
    digest = record.public_send(digest_attribute)
    assert_equal model.digest(secret), digest, "the persisted value must be the keyed digest of the plaintext"
    assert_not_equal secret, digest, "the digest must not be the plaintext"
    assert_not_includes record.attributes.values.map(&:to_s), secret,
      "no persisted column may contain the plaintext token"
    assert_nil record.token, "the plaintext must not be readable after reload"
  end

  def build_station
    station = RadioStation.new(name: "Lifecycle FM #{next_seq}", user: host)
    station.station_source_criteria.build(criterion_type: "artist", artist: artists(:artist1))
    station.save!
    station
  end

  def host
    users(:visitor1)
  end

  def default_library
    libraries(:default_library)
  end

  def next_seq
    @seq = (@seq || 0) + 1
  end

  # Remove every feature record touched by this property so each iteration
  # observes its own tokens in isolation. Ordered to respect foreign keys.
  # Fixture Songs/Albums/Artists are left intact so the station criterion
  # continues to select an authorized song.
  def reset_feature_data!
    StreamToken.delete_all
    StationSourceCriterion.delete_all
    RadioStation.delete_all
    ShareLink.delete_all
    Guest.delete_all
    PartySession.delete_all
    AccessGrant.delete_all
  end
end
