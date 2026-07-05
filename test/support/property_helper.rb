# frozen_string_literal: true

require "rantly"
require "rantly/property"

# PropertyHelper wires the `rantly` generator library into the project's
# Minitest suite so the multi-server-library-sharing correctness properties can
# be expressed as property-based tests.
#
# Every property-based test in this feature MUST:
#   * run a *minimum* of 100 generated iterations, and
#   * be tagged with a comment identifying the design property it validates, in
#     the exact format:
#
#       # Feature: multi-server-library-sharing, Property {number}: {property_text}
#
# Example:
#
#   # Feature: multi-server-library-sharing, Property 6: Invite code round-trips
#   test "invite codes round-trip" do
#     check_property do
#       # generator block: build and RETURN the value(s) under test using the
#       # Rantly generator DSL (self is a Rantly instance here).
#       [ string, sized(32) { string(:alnum) } ]
#     end.check do |(base_url, token)|
#       # assertion block: runs once per generated value. Any failing
#       # assertion is shrunk to a minimal counterexample by rantly and
#       # reported as the failing example.
#       code = InviteManager.encode(server_base_url: base_url, secret_token: token)
#       decoded = InviteManager.decode(code)
#       assert_equal base_url, decoded[:server_base_url]
#       assert_equal token, decoded[:secret_token]
#     end
#   end
#
# Splitting generation (the `check_property` block) from the assertions (the
# `.check` block) is what lets rantly shrink a failure down to a minimal
# counterexample and record it in the test output.
module PropertyHelper
  # The minimum number of iterations every property test must run. Callers may
  # request more, but never fewer.
  MINIMUM_ITERATIONS = 100

  # Build a property runner around a rantly generator block.
  #
  # @param iterations [Integer] requested iteration count; clamped up to
  #   MINIMUM_ITERATIONS so a property never runs fewer than 100 times.
  # @yield the rantly generator block; it is evaluated in the context of a
  #   Rantly instance and must return the value(s) under test.
  # @return [PropertyRunner]
  def check_property(iterations: MINIMUM_ITERATIONS, &generator)
    raise ArgumentError, "check_property requires a generator block" if generator.nil?

    effective_iterations = [ iterations.to_i, MINIMUM_ITERATIONS ].max
    PropertyRunner.new(effective_iterations, generator)
  end

  # Couples a rantly generator with its assertion block and runs the property.
  #
  # On the first assertion failure, rantly shrinks the generated input to a
  # minimal failing example and re-raises, so the counterexample is recorded in
  # the test output.
  class PropertyRunner
    def initialize(iterations, generator)
      @iterations = iterations
      @generator = generator
    end

    # @yield [value] the assertion block, invoked once per generated value.
    # @return [Object] rantly's check result when every iteration passes.
    def check(&assertion)
      raise ArgumentError, "check requires an assertion block" if assertion.nil?

      Rantly::Property.new(@generator).check(@iterations, &assertion)
    end
  end
end
