# frozen_string_literal: true

require "test_helper"

# Property-based test for Invite_Code encode/decode round-tripping.
#
# Design property (multi-server-library-sharing, Property 6):
#   For any Server base URL and secret token, decoding the Invite_Code produced
#   by encoding them SHALL yield back exactly those same two values.
#
# The generator exercises the interesting regions of the input space:
#   * arbitrary printable strings,
#   * URL-unsafe characters (`&`, `?`, `#`, `/`, `=`, spaces, quotes),
#   * unicode / multibyte content,
#   * empty and whitespace-only strings,
#   * long strings.
class InviteRoundTripPropertyTest < ActiveSupport::TestCase
  URL_UNSAFE = "&?#/=+ %\"'<>\\{}|^~[]`".chars.freeze
  UNICODE = "日本語🎵café–—“”€".chars.freeze

  # Feature: multi-server-library-sharing, Property 6: Invite code round-trips
  test "decode(encode(url, token)) yields the same base url and secret token" do
    check_property(iterations: 100) do
      # Build a candidate string covering the interesting input regions. This
      # block runs in the context of a Rantly instance, so the generator DSL
      # (choose/sized/range/string) is available on `self`. The lambda keeps
      # `self` bound to that Rantly instance, letting us generate two values.
      generate_value = lambda do
        case choose(:printable, :url_unsafe, :unicode, :empty_ish, :long)
        when :printable
          sized(range(0, 40)) { string(:print) }
        when :url_unsafe
          prefix = sized(range(0, 20)) { string(:alpha) }
          injected = Array.new(range(1, 6)) { choose(*URL_UNSAFE) }.join
          suffix = sized(range(0, 20)) { string(:alpha) }
          "#{prefix}#{injected}#{suffix}"
        when :unicode
          Array.new(range(1, 12)) { choose(*UNICODE) }.join
        when :empty_ish
          choose("", " ", "   ", "\t", "\n")
        when :long
          sized(range(500, 2000)) { string(:print) }
        end
      end

      [ generate_value.call, generate_value.call ]
    end.check do |(base_url, token)|
      code = InviteManager.encode(server_base_url: base_url, secret_token: token)
      decoded = InviteManager.decode(code)

      assert_equal base_url, decoded[:server_base_url],
        "base_url did not round-trip (code=#{code.inspect})"
      assert_equal token, decoded[:secret_token],
        "secret_token did not round-trip (code=#{code.inspect})"
    end
  end
end
