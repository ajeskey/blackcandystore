# frozen_string_literal: true

require "test_helper"

# Property-based test for the GuestAccessResolver library-scoping seam of the
# radio-party-colisten feature (design Property 15).
#
# Property 15 (Req 5.3, 5.4, 5.5, 8.2, 8.6): For any Guest request for a Song or
# Library, access (read or add) is granted iff the target belongs to a Library
# the session is configured to share. Any target outside that scope — whether it
# lives in a Library the session does not share OR does not exist at all (a nil
# library id) — yields the SAME negative result, so the caller cannot tell an
# out-of-scope target from a missing one (existence-hiding). Access is never
# widened beyond the shared libraries.
#
# The decision lives in two pure predicates that carry no side effects:
#   * GuestAccessResolver.content_in_scope?(content_library_id:, shared_library_ids:)
#   * GuestAccessResolver.content_accessible?(session:, content_library_id:)
#
# Each iteration builds a generated set of shared libraries and a content
# library id in one of three positions — in-scope, out-of-scope, or
# nil/nonexistent — and asserts the scoping decision, the existence-hiding
# equality of the two negatives, the record-based convenience matching the pure
# predicate, and that a granted access is only ever for an in-scope target.
class GuestScopingPropertyTest < ActiveSupport::TestCase
  # Feature: radio-party-colisten, Property 15: Guest access is strictly scoped to shared libraries with existence-hiding
  test "a guest may read or add content iff it belongs to a shared library, while out-of-scope content and non-existent content both yield the same existence-hiding negative and access is never widened" do
    check_property(iterations: 100) do
      # A shared-library set drawn from a small pool so both membership and
      # non-membership are exercised (and duplicates force normalization). An
      # empty set (no shared libraries) is included so nothing is ever in scope.
      shared_library_ids = Array.new(range(0, 6)) { range(1, 20) }
      # A candidate id used to synthesize an out-of-scope target.
      candidate = range(1, 100)
      # Which of the three request positions this iteration exercises.
      position = choose(:in_scope, :out_of_scope, :nil)

      [ shared_library_ids, candidate, position ]
    end.check do |(shared_library_ids, candidate, position)|
      shared_set = shared_library_ids.map(&:to_i).uniq.to_set

      # Resolve the generated position into a concrete content library id.
      # An in-scope request needs a non-empty shared set; when the set is empty
      # there is nothing in scope, so fall back to an out-of-scope target.
      content_library_id =
        case position
        when :nil
          nil
        when :in_scope
          shared_set.empty? ? out_of_scope_id(shared_set, candidate) : shared_set.to_a.sample
        else
          out_of_scope_id(shared_set, candidate)
        end

      # The target is in scope iff it exists (non-nil) and its library is shared.
      expected_in_scope = !content_library_id.nil? && shared_set.include?(content_library_id.to_i)

      result = GuestAccessResolver.content_in_scope?(
        content_library_id: content_library_id,
        shared_library_ids: shared_library_ids
      )
      assert_equal expected_in_scope, result,
        "access is granted iff the target's library is shared " \
        "(content=#{content_library_id.inspect} shared=#{shared_set.to_a.inspect})"

      # Existence-hiding: a non-existent target (nil library) is always a
      # negative, and an out-of-scope target yields the SAME negative, so the
      # two are indistinguishable to the caller (Req 5.4, 5.5, 8.6).
      nonexistent_result = GuestAccessResolver.content_in_scope?(
        content_library_id: nil,
        shared_library_ids: shared_library_ids
      )
      assert_equal false, nonexistent_result,
        "a non-existent target (nil library) must never be in scope"
      unless expected_in_scope
        assert_equal nonexistent_result, result,
          "an out-of-scope target must yield the same negative as a non-existent one"
      end

      # Access is never widened: a positive result is only ever for a target
      # whose library is in the shared set (Req 5.3, 8.2).
      if result
        assert shared_set.include?(content_library_id.to_i),
          "a granted access must belong to a shared library"
      end

      # Type-robustness: presenting the id as a string never widens or narrows
      # the decision (the seam normalizes with to_i).
      unless content_library_id.nil?
        string_result = GuestAccessResolver.content_in_scope?(
          content_library_id: content_library_id.to_s,
          shared_library_ids: shared_library_ids
        )
        assert_equal result, string_result,
          "the scoping decision must not depend on whether the id is an int or a string"
      end

      # The record-based convenience must agree with the pure predicate for the
      # same session scope (Property 15). Built in memory only — no persistence.
      session = PartySession.new(shared_library_ids: shared_library_ids)
      assert_equal result,
        GuestAccessResolver.content_accessible?(session: session, content_library_id: content_library_id),
        "content_accessible? must agree with content_in_scope? for the session's shared libraries"
    end
  end

  private

  # An id guaranteed to lie outside `shared_set`: strictly greater than every
  # shared id (and any candidate offset), so it can never be a member.
  def out_of_scope_id(shared_set, candidate)
    (shared_set.max || 0) + candidate.abs + 1
  end
end
