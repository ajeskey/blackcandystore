# frozen_string_literal: true

require "test_helper"

# Property-based test for Property 7 of the audiobook-resume-and-media-ui
# feature.
#
# Design property (audiobook-resume-and-media-ui, Property 7):
#   For any pair of a Server-held update time and a Client-presented update
#   time, reconciliation selects the side whose update time is more recent;
#   when the times are equal the Server-held record is selected as the source
#   of truth. This single rule governs both the Web_Player's local-vs-server
#   choice (Req 6.3) and the Server's client-vs-stored choice (Req 6.5).
#
# The pure seam under test is
# `Playback::PositionReconciler.choose(server_updated_at:, client_updated_at:)`,
# which returns :client when the client is strictly newer and :server
# otherwise. A nil client resolves to :server; a nil server with a non-nil
# client resolves to :client; ties resolve to :server.
#
# The generator produces timestamp pairs spanning every relevant situation:
#   * :both_nil     - neither side has a timestamp
#   * :nil_client   - only the Server has a timestamp
#   * :nil_server   - only the Client has a timestamp
#   * :equal        - identical timestamps (tie)
#   * :client_newer - client strictly after server
#   * :server_newer - server strictly after client
class PositionReconciliationPropertyTest < ActiveSupport::TestCase
  SCENARIOS = %i[both_nil nil_client nil_server equal client_newer server_newer].freeze

  # Feature: audiobook-resume-and-media-ui, Property 7: Reconciliation prefers the most recent update
  test "reconciliation selects the more-recently-updated side, with ties and nil-client resolving to the server" do
    check_property(iterations: 100) do
      scenario = SCENARIOS[range(0, SCENARIOS.length - 1)]
      # A base epoch second and a strictly-positive delta so "newer"/"older"
      # sides are unambiguous.
      base = range(0, 2_000_000_000)
      delta = range(1, 100_000)

      server_time, client_time =
        case scenario
        when :both_nil     then [ nil, nil ]
        when :nil_client   then [ Time.at(base), nil ]
        when :nil_server   then [ nil, Time.at(base) ]
        when :equal        then [ Time.at(base), Time.at(base) ]
        when :client_newer then [ Time.at(base), Time.at(base + delta) ]
        when :server_newer then [ Time.at(base + delta), Time.at(base) ]
        end

      [ scenario, server_time, client_time ]
    end.check do |(scenario, server_time, client_time)|
      choice = Playback::PositionReconciler.choose(
        server_updated_at: server_time,
        client_updated_at: client_time
      )

      # The result is always one of the two sides.
      assert_includes %i[server client], choice,
        "choose must return :server or :client, got #{choice.inspect}"

      # Client wins only when it is strictly newer (Req 6.3); every other
      # situation resolves to the authoritative Server record (Req 6.5).
      expected =
        case scenario
        when :client_newer then :client
        when :nil_server   then :client # non-nil client, nil server => client
        else :server                    # both_nil, nil_client, equal (tie), server_newer
        end

      assert_equal expected, choice,
        "for scenario #{scenario} with server=#{server_time.inspect} " \
        "client=#{client_time.inspect}, expected #{expected} but got #{choice}"

      # Cross-check the core invariant directly: :client iff a client timestamp
      # exists and is strictly greater than the server timestamp (nil server
      # counts as "older"); :server in every other case.
      client_strictly_newer =
        !client_time.nil? && (server_time.nil? || client_time > server_time)
      assert_equal (client_strictly_newer ? :client : :server), choice,
        "most-recent-wins invariant violated for #{scenario}"
    end
  end
end
