# frozen_string_literal: true

require "test_helper"

# Unit tests for the StreamToken model (Req 11.5). Covers digest-only
# persistence of the plaintext token, constant-time verification and lookup,
# the belongs_to radio_station wiring, and the active/revoked status lifecycle.
class StreamTokenTest < ActiveSupport::TestCase
  setup do
    @user = users(:visitor1)
    @station = RadioStation.new(name: "Token FM", user: @user)
    @station.station_source_criteria.build(criterion_type: "artist", artist: artists(:artist1))
    @station.save!
  end

  def build_token(token: "stream-secret", **attrs)
    StreamToken.new(radio_station: @station, token: token, **attrs)
  end

  # --- Association wiring --------------------------------------------------

  test "belongs to a radio station" do
    token = build_token
    assert token.save
    assert_equal @station, token.reload.radio_station
  end

  test "the station exposes its stream token through has_one" do
    token = build_token
    token.save!
    assert_equal token, @station.reload.stream_token
  end

  test "requires a radio_station" do
    token = StreamToken.new(token: "abc")
    assert_not token.valid?
    assert_includes token.errors.attribute_names, :radio_station
  end

  test "requires a token_digest" do
    token = StreamToken.new(radio_station: @station)
    assert_not token.valid?
    assert_includes token.errors.attribute_names, :token_digest
  end

  # --- Digest-only persistence (Req 11.5) ----------------------------------

  test "stores the token hashed rather than in plaintext" do
    token = build_token(token: "plaintext-stream")
    assert_not_nil token.token_digest
    assert_not_equal "plaintext-stream", token.token_digest
    assert_equal StreamToken.digest("plaintext-stream"), token.token_digest
  end

  test "retains the plaintext token only in memory and never after reload" do
    token = build_token(token: "one-time-stream")
    token.save!
    assert_equal "one-time-stream", token.token
    assert_nil StreamToken.find(token.id).token
  end

  test "digest is deterministic for the same token and differs for different tokens" do
    assert_equal StreamToken.digest("st-a"), StreamToken.digest("st-a")
    assert_not_equal StreamToken.digest("st-a"), StreamToken.digest("st-b")
  end

  # --- Constant-time verification and lookup -------------------------------

  test "authenticate_token verifies with a constant-time comparison" do
    token = build_token(token: "right-stream-token")
    assert token.authenticate_token("right-stream-token")
    assert_not token.authenticate_token("wrong-token")
    assert_not token.authenticate_token(nil)
    assert_not token.authenticate_token("")
  end

  test "find_by_token returns the matching token" do
    token = build_token(token: "lookup-stream")
    token.save!
    assert_equal token, StreamToken.find_by_token("lookup-stream")
  end

  test "find_by_token returns nil for an unknown or blank token" do
    build_token(token: "known-stream").save!
    assert_nil StreamToken.find_by_token("no-such-stream")
    assert_nil StreamToken.find_by_token(nil)
    assert_nil StreamToken.find_by_token("")
  end

  # --- Status lifecycle (Req 11.5) -----------------------------------------

  test "defaults to active status and is usable" do
    token = build_token
    token.save!
    assert token.active?
    assert token.usable?
  end

  test "revoke! transitions to revoked and makes the token unusable" do
    token = build_token
    token.save!

    token.revoke!
    assert token.revoked?
    assert_not token.usable?
  end

  test "revoke! is idempotent" do
    token = build_token
    token.save!
    token.revoke!
    assert_nothing_raised { token.revoke! }
    assert token.reload.revoked?
  end

  test "active and revoked scopes select by status" do
    active_token = build_token(token: "active-stream")
    active_token.save!
    revoked_station = RadioStation.new(name: "Revoked FM", user: @user)
    revoked_station.station_source_criteria.build(criterion_type: "artist", artist: artists(:artist1))
    revoked_station.save!
    revoked_token = StreamToken.create!(radio_station: revoked_station, token: "revoked-stream", status: :revoked)

    assert_includes StreamToken.active, active_token
    assert_not_includes StreamToken.active, revoked_token
    assert_includes StreamToken.revoked, revoked_token
    assert_not_includes StreamToken.revoked, active_token
  end
end
