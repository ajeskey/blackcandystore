# frozen_string_literal: true

require "test_helper"

# Property-based test for Property 13 of the radio-party-colisten feature.
#
# Design property (radio-party-colisten, Property 13):
#   For any set of libraries a Host attempts to share on a Party_Session or
#   Co_Listen_Session, the selection is accepted iff every library is in the
#   Host's `authorized_library_ids`; any library outside that set is rejected
#   and the session's shared-library set is unchanged.
#
#   Validates: Requirements 4.7
#
# Both session models mix in SharedSessionConcern, whose
# `shared_libraries_within_host_authorization` validation implements the
# subset rule. The `shared_library_ids` jsonb column is normalized to a
# de-duplicated set of integers before the check, so the test exercises
# integer, duplicate, and out-of-range ids against a host with a known
# authorized-library set.
#
# The host's authorized libraries are the local libraries the host owns
# (`User#authorized_library_ids` = owned-local + active-remote). The generator
# draws candidate selections from a pool of the host's authorized library ids,
# other users' (unauthorized) library ids, and never-existing ids, so every
# region of the input space — pure-authorized (accept), any-unauthorized
# (reject), empty (vacuously accept), and duplicates — is covered.
class SharedSessionPropertyTest < ActiveSupport::TestCase
  MEDIA_PATH = Rails.root.join("test", "fixtures", "files").to_s
  # Ids that belong to no Library, so they can never be authorized.
  NONEXISTENT_IDS = [ 987_654, 987_655 ].freeze

  setup do
    @host = User.create!(email: "prop13-host-#{SecureRandom.uuid}@example.com", password: "foobar123")
    other = User.create!(email: "prop13-other-#{SecureRandom.uuid}@example.com", password: "foobar123")

    # Libraries the host owns are authorized for the host.
    @authorized_ids = Array.new(3) { create_local_library(owner: @host).id }
    # Libraries owned by someone else are NOT in the host's authorization.
    @unauthorized_ids = Array.new(2) { create_local_library(owner: other).id }

    @authorized_set = @host.authorized_library_ids.map(&:to_i).to_set
    @pool = @authorized_ids + @unauthorized_ids + NONEXISTENT_IDS
  end

  # Feature: radio-party-colisten, Property 13: Shared libraries are a subset of the host's authorized libraries
  test "a session's shared-library selection is accepted iff every id is in the host's authorized libraries" do
    check_property(iterations: 100) do
      # Pick which session model to exercise and build a candidate selection by
      # sampling the pool (0..6 entries, duplicates allowed to hit normalize).
      klass_name = choose("PartySession", "CoListenSession")
      selection = Array.new(range(0, 6)) { choose(*@pool) }
      [ klass_name, selection ]
    end.check do |(klass_name, selection)|
      klass = klass_name.constantize

      normalized = selection.map(&:to_i).uniq
      expected_accept = normalized.all? { |id| @authorized_set.include?(id) }

      # --- create path -----------------------------------------------------
      session = klass.new(user: @host, shared_library_ids: selection)
      saved = session.save

      assert_equal expected_accept, saved,
        "#{klass_name} selection=#{selection.inspect} normalized=#{normalized.inspect} " \
        "authorized=#{@authorized_set.to_a.inspect} errors=#{session.errors.full_messages.inspect}"

      unless saved
        assert_includes session.errors.attribute_names, :shared_library_ids,
          "rejection must be attributed to shared_library_ids"
      end

      session.destroy if session.persisted?

      # --- update path: rejection leaves the shared-library set unchanged ---
      # Start from a known-good empty selection, then attempt the candidate.
      baseline = klass.create!(user: @host, shared_library_ids: [])
      updated = baseline.update(shared_library_ids: selection)

      assert_equal expected_accept, updated,
        "#{klass_name} update selection=#{selection.inspect} errors=#{baseline.errors.full_messages.inspect}"

      baseline.reload
      unless expected_accept
        assert_equal [], baseline.shared_library_ids,
          "a rejected update must leave the session's shared-library set unchanged"
      end

      baseline.destroy
    end
  end

  private

  def create_local_library(owner:)
    Library.create!(
      name: "Prop13-#{SecureRandom.uuid}",
      kind: "local",
      media_path: MEDIA_PATH,
      owner:
    )
  end
end
