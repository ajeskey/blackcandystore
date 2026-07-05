# frozen_string_literal: true

require "test_helper"

# Property-based test for malformed Invite_Code rejection without side effects.
#
# Design property (multi-server-library-sharing, Property 7):
#   For any string that is not a valid Invite_Code encoding, redemption SHALL be
#   rejected as malformed and SHALL leave the User's existing access unchanged.
#
# InviteManager.redeem is not implemented yet (task 11.1). Redemption begins by
# decoding the submitted code, so this test exercises the decode-level malformed
# rejection that any redemption path must go through: a string that cannot be
# decoded into a Server base URL and secret token is rejected with
# InviteManager::Malformed (Req 5.3), and because rejection happens before any
# persistence, no Access_Grant or Library_Connection is created (existing access
# is left unchanged).
#
# The generator covers the interesting regions of the malformed input space:
#   * empty / whitespace-only strings,
#   * non-ASCII / multibyte unicode garbage,
#   * random garbage containing characters outside the Base64URL alphabet,
#   * well-formed Base64URL that decodes to non-JSON bytes,
#   * well-formed Base64URL of JSON that is not an object, or an object missing
#     the required `u` / `t` string fields.
#
# A random string could, extremely rarely, happen to be a valid encoding, so the
# generator re-rolls any candidate that decodes successfully. This keeps the
# input space restricted to strings that are genuinely NOT valid Invite_Codes.
class MalformedInviteRejectionPropertyTest < ActiveSupport::TestCase
  NON_ASCII = "日本語🎵café–—“”€✓✗♪∆".chars.freeze
  # Characters that are NOT part of the unpadded Base64URL alphabet
  # ([A-Za-z0-9_-]); their presence makes urlsafe_decode64 reject the input.
  NON_BASE64 = "!@#$%^&*()=+/ ?<>,.:;'\"\\{}|[]`~".chars.freeze

  # Feature: multi-server-library-sharing, Property 7: Malformed invite codes are rejected without side effects
  test "decoding a malformed invite code raises Malformed and creates no access" do
    grants_before = AccessGrant.count
    connections_before = LibraryConnection.count

    # True when the candidate decodes into a valid Invite_Code (i.e. it is NOT
    # malformed), used by the generator to discard accidentally-valid inputs.
    # Defined as a lambda so it is callable from inside the Rantly generator
    # block, whose `self` is a Rantly instance rather than this test case.
    decodable = lambda do |candidate|
      InviteManager.decode(candidate)
      true
    rescue InviteManager::Malformed
      false
    end

    check_property(iterations: 200) do
      # Produce a candidate string that is guaranteed-or-verified to be an
      # invalid Invite_Code. This block runs as a Rantly instance, so the
      # generator DSL (choose/range/sized/string) is available on `self`.
      build_candidate = lambda do
        case choose(:blank, :non_ascii, :non_base64_garbage, :base64_non_json, :base64_wrong_shape)
        when :blank
          choose("", " ", "   ", "\t", "\n", "\t \n")
        when :non_ascii
          Array.new(range(1, 12)) { choose(*NON_ASCII) }.join
        when :non_base64_garbage
          prefix = sized(range(0, 10)) { string(:alpha) }
          injected = Array.new(range(1, 6)) { choose(*NON_BASE64) }.join
          suffix = sized(range(0, 10)) { string(:alpha) }
          "#{prefix}#{injected}#{suffix}"
        when :base64_non_json
          # Valid Base64URL, but the decoded bytes are not parseable JSON.
          raw = sized(range(1, 30)) { string(:alpha) }
          Base64.urlsafe_encode64(raw, padding: false)
        when :base64_wrong_shape
          # Valid Base64URL of valid JSON that is either not an object or an
          # object lacking the required string `u` / `t` fields.
          json = choose(
            JSON.generate(range(-1000, 1000)),
            JSON.generate(sized(range(0, 8)) { string(:alpha) }),
            JSON.generate(Array.new(range(0, 4)) { range(0, 9) }),
            JSON.generate({}),
            JSON.generate({ "u" => sized(range(0, 8)) { string(:alpha) } }),
            JSON.generate({ "t" => sized(range(0, 8)) { string(:alpha) } }),
            JSON.generate({ "u" => range(0, 9), "t" => range(0, 9) })
          )
          Base64.urlsafe_encode64(json, padding: false)
        end
      end

      # Re-roll on the astronomically unlikely chance a random candidate is in
      # fact a decodable Invite_Code, so we only ever assert on genuine garbage.
      candidate = build_candidate.call
      attempts = 0
      while (attempts += 1) <= 50 && decodable.call(candidate)
        candidate = build_candidate.call
      end

      candidate
    end.check do |candidate|
      assert_raises(InviteManager::Malformed, "expected #{candidate.inspect} to be rejected as malformed") do
        InviteManager.decode(candidate)
      end

      # No side effects: existing access is left unchanged.
      assert_equal grants_before, AccessGrant.count,
        "decoding #{candidate.inspect} changed the AccessGrant count"
      assert_equal connections_before, LibraryConnection.count,
        "decoding #{candidate.inspect} changed the LibraryConnection count"
    end
  end
end
