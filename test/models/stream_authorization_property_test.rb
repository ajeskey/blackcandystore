# frozen_string_literal: true

require "test_helper"

# Property-based tests for the Radio_Station Stream_Endpoint authorization seam
# of the radio-party-colisten feature (design Property 9).
#
# Property 9 governs *who* is allowed to hear a station's Shared_Stream, for any
# Stream_Visibility: audio is served iff
#   * the station is `public`, OR
#   * a valid, non-revoked Stream_Token matching the station's keyed digest is
#     presented (embedded in the Stream_Endpoint URL), OR
#   * the request presents a valid credential for an authorized account;
# in every other case the request is rejected and no audio is delivered.
#
# This is exercised at two layers:
#   1. The pure `StreamTokenService.stream_authorized?` decision, over the full
#      boolean input space of the three radio authorization facts (visibility,
#      token validity, account authorization), asserting the decision is exactly
#      their disjunction and that the all-false case rejects.
#   2. The record-based `StreamTokenService.radio_stream_authorized?`, driven by
#      *real* persisted `StreamToken` keyed digests across the token lifecycle
#      (valid / rotated / revoked / never-generated) and both visibilities, so
#      the digest-matching half of the rule is validated end-to-end rather than
#      as a stubbed boolean.
class StreamAuthorizationPropertyTest < ActiveSupport::TestCase
  # A readable directory so freshly created local libraries pass media-path
  # validation; the fixtures directory always exists.
  MEDIA_PATH = Rails.root.join("test", "fixtures", "files").to_s

  setup do
    @seq = 0
    @fixture_library_ids = [ libraries(:default_library).id, libraries(:secondary_library).id ]
  end

  # Feature: radio-party-colisten, Property 9: Stream authorization by visibility
  test "the pure stream_authorized? decision serves audio iff the station is public, a valid stream token matched, or the account is authorized, and rejects when none hold" do
    check_property(iterations: 100) do
      # The three radio authorization facts, each independently true/false, so
      # every one of the eight combinations is reachable.
      [ choose(true, false), choose(true, false), choose(true, false) ]
    end.check do |(public_stream, stream_token_valid, account_authorized)|
      authorized = StreamTokenService.stream_authorized?(
        public_stream: public_stream,
        stream_token_valid: stream_token_valid,
        account_authorized: account_authorized
      )

      expected = public_stream || stream_token_valid || account_authorized

      assert_equal expected, authorized,
        "audio is served iff public OR valid-token OR authorized-account " \
        "(public=#{public_stream}, token=#{stream_token_valid}, account=#{account_authorized})"

      unless public_stream || stream_token_valid || account_authorized
        assert_not authorized,
          "with no valid credential the request must be rejected with no audio"
      end
    end
  end

  # Feature: radio-party-colisten, Property 9: Stream authorization by visibility
  test "record-based radio_stream_authorized? matches real StreamToken keyed digests across the token lifecycle and honors public visibility" do
    check_property(iterations: 100) do
      # Stream_Visibility of the station, the lifecycle state of its
      # Stream_Token, which plaintext (if any) the request embeds, and whether
      # the request also carries an authorized-account credential.
      visibility = choose("authenticated", "public")
      token_state = choose(:none, :valid, :rotated, :revoked)
      presented = choose(:current, :old, :wrong, :nil)
      account_authorized = choose(true, false)

      [ visibility, token_state, presented, account_authorized ]
    end.check do |(visibility, token_state, presented, account_authorized)|
      reset_dataset!
      station = build_station(visibility)

      # Establish the requested token lifecycle state with real secrets and
      # remember the two plaintexts that ever existed for this station.
      first_secret = SecureRandom.urlsafe_base64(32)
      second_secret = SecureRandom.urlsafe_base64(32)
      wrong_secret = SecureRandom.urlsafe_base64(32)
      current_secret = nil

      case token_state
      when :none
        # No Stream_Token ever generated.
      when :valid
        StreamTokenService.issue_radio_token(station, raw_token: first_secret)
        current_secret = first_secret
      when :rotated
        StreamTokenService.issue_radio_token(station, raw_token: first_secret)
        StreamTokenService.rotate_radio_token(station, raw_token: second_secret)
        current_secret = second_secret
      when :revoked
        StreamTokenService.issue_radio_token(station, raw_token: first_secret)
        StreamTokenService.revoke_radio_token(station)
        current_secret = nil # a revoked token authorizes no plaintext
      end

      # Read the station back from the database so authorization decisions run
      # against the persisted keyed digest and status, not in-memory plaintext.
      station.reload

      raw_token =
        case presented
        when :current then current_secret # nil for :none and :revoked
        when :old     then first_secret
        when :wrong   then wrong_secret
        when :nil     then nil
        end

      # The only plaintext that a usable (active, non-revoked) token
      # authenticates is its current secret: `first_secret` for a never-rotated
      # `:valid` token and `second_secret` after a rotation. A `:none` station
      # (no token) and a `:revoked` token have no usable secret at all.
      usable_secret =
        case token_state
        when :valid   then first_secret
        when :rotated then second_secret
        else               nil
        end

      # The token is a valid credential iff the station currently has a usable
      # token AND the presented plaintext is exactly its current secret. (For a
      # never-rotated token the "old" plaintext equals the current secret, so it
      # still authorizes; after a rotation or revocation it no longer does.)
      token_valid_fact = raw_token.present? && usable_secret.present? && raw_token == usable_secret

      expected = (visibility == "public") || token_valid_fact || account_authorized

      authorized = StreamTokenService.radio_stream_authorized?(
        radio_station: station,
        raw_token: raw_token,
        account_authorized: account_authorized
      )

      assert_equal expected, authorized,
        "radio_stream_authorized? must serve audio iff public OR a usable token " \
        "matched OR account authorized (visibility=#{visibility}, token=#{token_state}, " \
        "presented=#{presented}, account=#{account_authorized})"

      # Cross-check the digest half in isolation: valid_radio_token? is true
      # exactly when a usable token matches the presented plaintext.
      assert_equal token_valid_fact,
        StreamTokenService.valid_radio_token?(station, raw_token),
        "valid_radio_token? must reflect the persisted digest and lifecycle status"

      # A rotated or revoked token must never authorize a previously distributed
      # (old) plaintext.
      if presented == :old && token_state.in?(%i[rotated revoked])
        assert_not StreamTokenService.valid_radio_token?(station, raw_token),
          "a #{token_state} token must not authorize the old plaintext"
      end
    end
  end

  private

  def next_seq
    @seq += 1
  end

  # Wipe all station/token/content and every non-fixture library so each
  # iteration observes only the dataset it builds.
  def reset_dataset!
    StreamToken.delete_all
    StationSourceCriterion.delete_all
    RadioStation.delete_all
    Song.delete_all
    Album.delete_all
    Artist.delete_all
    Library.where.not(id: @fixture_library_ids).delete_all
  end

  # Build and persist a valid Radio_Station with the given Stream_Visibility: an
  # owning User with one authorized (owned) local library holding a single Song,
  # selected by an artist criterion so the eligible set is non-empty.
  def build_station(visibility)
    owner = User.create!(email: "streamauth-owner-#{SecureRandom.uuid}@example.com", password: "foobar123")
    library = Library.create!(name: "StreamAuth-#{next_seq}", kind: "local", media_path: MEDIA_PATH, owner: owner)

    n = next_seq
    artist = Artist.create!(name: "Artist-#{n}", library: library)
    album = Album.create!(name: "Album-#{n}", artist: artist, library: library, genre: "rock")
    Song.create!(
      name: "Song-#{n}",
      file_path: "/tmp/streamauth-song-#{n}.mp3",
      file_path_hash: "fph-#{n}",
      md5_hash: "md5-#{n}",
      library: library,
      album: album,
      artist: artist
    )

    station = RadioStation.new(user: owner, name: "Station-#{n}", stream_visibility: visibility)
    station.station_source_criteria.build(criterion_type: "artist", artist_id: artist.id)
    station.save!
    station
  end
end
