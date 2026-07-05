# frozen_string_literal: true

require "test_helper"

# Property-based test for library name acceptance.
#
# Design property (multi-server-library-sharing, Property 1):
#   For any candidate library name, the Server SHALL accept it if and only if
#   its whitespace-trimmed length is between 1 and 255 characters and it does
#   not duplicate (case-insensitively) an existing local library name on the
#   Server; rejected submissions SHALL leave every existing library unchanged.
#
# The test isolates name validation by creating candidates as `remote`
# libraries so the local-only media_path validation does not interfere; the
# name validations (presence, length, case-insensitive uniqueness) apply to
# every kind of library identically.
class LibraryNameAcceptancePropertyTest < ActiveSupport::TestCase
  NAME_MIN_LENGTH = 1
  NAME_MAX_LENGTH = 255
  EXISTING_NAME = "Existing Library"

  setup do
    @owner = users(:admin)
    # Ensure a known library name exists so the case-variant duplicate branch of
    # the generator has a real collision target. Duplicate detection in the
    # assertion reads the live set of names, so any other pre-existing libraries
    # (e.g. the fixture's Default Library) are accounted for automatically.
    @existing = Library.create!(name: EXISTING_NAME, kind: "remote", owner: @owner)
  end

  # Feature: multi-server-library-sharing, Property 1: Library name acceptance is valid-and-unique
  test "library name is accepted iff trimmed length 1-255 and not a case-insensitive duplicate" do
    check_property(iterations: 100) do
      # Generate candidate names covering the interesting regions of the input
      # space: arbitrary strings, whitespace-only, case-variant duplicates, and
      # values on either side of the length boundaries.
      case choose(:random, :whitespace, :case_variant, :boundary, :too_long)
      when :random
        sized(range(0, 300)) { string(:print) }
      when :whitespace
        sized(range(1, 8)) { string(:space) }
      when :case_variant
        variant = choose(EXISTING_NAME.upcase, EXISTING_NAME.downcase, EXISTING_NAME.swapcase, EXISTING_NAME)
        pad = " " * range(0, 3)
        "#{pad}#{variant}#{pad}"
      when :boundary
        sized(choose(1, 2, 254, 255)) { string(:alpha) }
      when :too_long
        sized(choose(256, 257, 300)) { string(:alpha) }
      end
    end.check do |candidate|
      before_state = Library.order(:id).pluck(:id, :name, :kind)

      existing_names = before_state.map { |(_, name, _)| name }
      trimmed = candidate.strip
      valid_length = trimmed.length.between?(NAME_MIN_LENGTH, NAME_MAX_LENGTH)
      duplicate = existing_names.any? { |name| name.casecmp?(trimmed) }
      expected_accept = valid_length && !duplicate

      library = Library.new(name: candidate, kind: "remote", owner: @owner)
      saved = library.save

      assert_equal expected_accept, saved,
        "candidate=#{candidate.inspect} trimmed=#{trimmed.inspect} " \
        "(length=#{trimmed.length}, duplicate=#{duplicate}) errors=#{library.errors.full_messages.inspect}"

      if saved
        # Restore the known single-library state for the next iteration.
        library.destroy!
      else
        # A rejected submission must leave every existing library unchanged.
        assert_equal before_state, Library.order(:id).pluck(:id, :name, :kind),
          "rejected candidate=#{candidate.inspect} changed existing libraries"
      end
    end
  end
end
