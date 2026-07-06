# frozen_string_literal: true

require "test_helper"

# Property-based test for the mutation / lifecycle authority seam of the
# radio-party-colisten feature (design Property 4).
#
# AuthorizationPolicy.mutation_authorized?(actor, owner_id) — delegating to
# BroadcastLifecycle.authorized? — is the pure predicate the controllers and
# lifecycle services consult before any create/modify/delete or
# start/stop/activate/deactivate on a Radio_Station or Co_Listen_Session. The
# rule (Req 1.8, 10.3, 10.9) is:
#
#   permitted iff the actor is a full User account who either owns the subject
#   (actor.id == subject.user_id) or is an Admin; a Guest or an anonymous (nil)
#   caller is never permitted, regardless of any coincidental id overlap.
#
# Each iteration builds an isolated subject — a Radio_Station (which requires
# criteria selecting at least one authorized Song to persist) or a
# Co_Listen_Session — in a generated state, then evaluates the predicate for a
# generated actor kind (owner, admin, other user, guest, nil) against the
# subject's owning user_id. Because the predicate is pure (it reads state and
# returns a boolean, mutating nothing), the subject's persisted state is
# snapshotted before and after the decision to confirm a rejection — like a
# grant — leaves the subject unchanged.
class MutationAuthorityPropertyTest < ActiveSupport::TestCase
  # A readable directory so freshly created local libraries pass media-path
  # validation; the fixtures directory always exists.
  MEDIA_PATH = Rails.root.join("test", "fixtures", "files").to_s

  # The actor kinds exercised against every subject. Only :owner and :admin are
  # ever authorized.
  ACTOR_KINDS = %i[owner admin other guest nil].freeze
  AUTHORIZED_KINDS = %i[owner admin].freeze

  setup do
    @seq = 0
    @fixture_library_ids = [ libraries(:default_library).id, libraries(:secondary_library).id ]
  end

  # Feature: radio-party-colisten, Property 4: Mutation and lifecycle authority
  test "a mutation or lifecycle operation is authorized iff the actor is the owning User/Host or an Admin, and a rejected decision leaves the subject's state unchanged" do
    check_property(iterations: 100) do
      subject_kind = choose(:station, :session)
      actor_kind = choose(*ACTOR_KINDS)
      # A generated persisted state so authority is shown to be independent of
      # the subject's lifecycle position.
      state = subject_kind == :station ? choose("stopped", "started") : choose("active", "ended")

      [ subject_kind, actor_kind, state ]
    end.check do |(subject_kind, actor_kind, state)|
      reset_dataset!
      owner = create_user

      subject = subject_kind == :station ? build_station(owner, state) : build_session(owner, state)
      actor = build_actor(actor_kind, owner)

      expected = AUTHORIZED_KINDS.include?(actor_kind)
      before = subject.attributes

      permitted = AuthorizationPolicy.mutation_authorized?(actor, subject.user_id)

      assert_equal expected, permitted,
        "#{actor_kind} acting on a #{subject_kind} (owner_id=#{subject.user_id}) should be " \
        "#{expected ? "permitted" : "rejected"}"

      # A pure decision never mutates the subject — a rejection leaves it exactly
      # as it was (Property 4's "no state change").
      subject.reload
      assert_equal before, subject.attributes,
        "evaluating authority must not change the #{subject_kind}'s state"

      # A Guest is never a User, so id overlap with the owner grants no authority:
      # even asked about its own id as the owner, a Guest is still rejected.
      if actor_kind == :guest
        assert_not AuthorizationPolicy.mutation_authorized?(actor, actor.id),
          "a Guest is never authorized, even when its id coincides with the owner_id"
      end
    end
  end

  private

  def next_seq
    @seq += 1
  end

  # Wipe all feature records and every non-fixture library/content row so each
  # iteration observes only the subject it builds.
  def reset_dataset!
    Guest.delete_all
    CoListenSession.delete_all
    StationSourceCriterion.delete_all
    StreamToken.delete_all
    RadioStation.delete_all
    Song.delete_all
    Album.delete_all
    Artist.delete_all
    Library.where.not(id: @fixture_library_ids).delete_all
  end

  def create_user
    User.create!(email: "mut-auth-#{SecureRandom.uuid}@example.com", password: "foobar123")
  end

  def create_admin
    User.create!(email: "mut-auth-admin-#{SecureRandom.uuid}@example.com", password: "foobar123", is_admin: true)
  end

  # Build the actor for the given kind. :owner is the subject's owning User;
  # :admin is a distinct Admin account; :other is a distinct non-admin User;
  # :guest is a Guest admitted to a throwaway session; :nil is an anonymous
  # caller.
  def build_actor(actor_kind, owner)
    case actor_kind
    when :owner then owner
    when :admin then create_admin
    when :other then create_user
    when :guest then Guest.create!(sessionable: build_session(create_user, "active"), token: "guest-#{next_seq}")
    when :nil then nil
    end
  end

  # Build a persisted Radio_Station in the given Station_State. A station needs
  # criteria that select at least one authorized Song to save, so a dedicated
  # owned library + Artist/Album/Song triad is created and selected by artist.
  def build_station(owner, state)
    library = Library.create!(name: "MutAuth-Lib-#{next_seq}", kind: "local", media_path: MEDIA_PATH, owner: owner)
    n = next_seq
    artist = Artist.create!(name: "Artist-#{n}", library: library)
    album = Album.create!(name: "Album-#{n}", artist: artist, library: library, genre: "rock")
    Song.create!(
      name: "Song-#{n}",
      file_path: "/tmp/mut-auth-song-#{n}.mp3",
      file_path_hash: "fph-#{n}",
      md5_hash: "md5-#{n}",
      library: library,
      album: album,
      artist: artist
    )

    station = RadioStation.new(user: owner, name: "Station-#{next_seq}", state: state)
    station.station_source_criteria.build(criterion_type: "artist", artist_id: artist.id)
    station.save!
    station
  end

  # Build a persisted Co_Listen_Session in the given Session_State. An empty
  # shared-library set is a valid subset of any host's authorization.
  def build_session(owner, state)
    CoListenSession.create!(user: owner, state: state)
  end
end
