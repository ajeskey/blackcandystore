# frozen_string_literal: true

require "test_helper"

# Unit tests for the Source_Preference resolver (Req 11.3–11.9, 12.6, 12.11).
class SourcePreferenceTest < ActiveSupport::TestCase
  setup do
    @user = users(:visitor1)
    # The Default_Library is owned by visitor1 (see fixtures), so it is the
    # User's own Local_Library for the "own copy" rules.
    @own_library = libraries(:default_library)
    @other_local = libraries(:secondary_library)
    @counter = 0
  end

  # --- prefer_own_server -----------------------------------------------------

  # Req 11.4: with prefer_own_server the copy in the User's own Local_Library is
  # selected even when another accessible copy is higher quality.
  test "prefer_own_server selects the own-library copy over a higher-quality other copy" do
    prefer_own_server

    own = build_song(library: @own_library, bit_depth: nil)        # lossy own copy
    build_song(library: @other_local, bit_depth: 24)               # higher quality, not owned

    assert_equal own, SourcePreference.select([ own, Song.last ], user: @user)
  end

  # Req 11.7: with prefer_own_server and no copy in the User's own library, the
  # highest-quality available copy is selected instead.
  test "prefer_own_server falls back to highest quality when no own copy exists" do
    prefer_own_server
    lib_a = create_local_library
    lib_b = create_local_library

    lossy = build_song(library: lib_a, bit_depth: nil)
    lossless = build_song(library: lib_b, bit_depth: 16)

    assert_equal lossless, SourcePreference.select([ lossy, lossless ], user: @user)
  end

  # --- prefer_highest_quality ------------------------------------------------

  # Req 11.5: lossless status ranks above lossy, regardless of ownership.
  test "prefer_highest_quality selects the lossless copy over a lossy own copy" do
    prefer_highest_quality
    remote = remote_library

    own_lossy = build_song(library: @own_library, bit_depth: nil)
    remote_lossless = build_song(library: remote, bit_depth: 16)

    assert_equal remote_lossless, SourcePreference.select([ own_lossy, remote_lossless ], user: @user)
  end

  # Req 11.5: among lossless copies, higher bit depth wins.
  test "prefer_highest_quality breaks ties on bit depth" do
    prefer_highest_quality
    lib_a = create_local_library
    lib_b = create_local_library

    depth16 = build_song(library: lib_a, bit_depth: 16)
    depth24 = build_song(library: lib_b, bit_depth: 24)

    assert_equal depth24, SourcePreference.select([ depth16, depth24 ], user: @user)
  end

  # --- tiebreaks (Req 11.8) --------------------------------------------------

  # Req 11.8: equal-quality copies tie-break to the User's own Local_Library.
  test "ties prefer the own-library copy first" do
    prefer_highest_quality

    own = build_song(library: @own_library, bit_depth: 16)
    other = build_song(library: @other_local, bit_depth: 16)

    assert_equal own, SourcePreference.select([ other, own ], user: @user)
  end

  # Req 11.8: with no own copy, equal-quality copies tie-break to the lowest
  # actual Library identifier.
  test "ties prefer the lowest library id when no own copy exists" do
    prefer_highest_quality
    lib_a = create_local_library
    lib_b = create_local_library

    song_a = build_song(library: lib_a, bit_depth: 16)
    song_b = build_song(library: lib_b, bit_depth: 16)

    selected = SourcePreference.select([ song_b, song_a ], user: @user)
    assert_equal [ lib_a.id, lib_b.id ].min, selected.library_id
    assert_equal song_a, selected
  end

  # --- availability (Req 11.9, 12.7, 12.11) ----------------------------------

  # Req 11.9 / 12.11: when no accessible copy remains, no Song is selected.
  test "returns nil when no accessible copy remains" do
    prefer_own_server
    revoked = remote_library(status: :revoked)

    unavailable = build_song(library: revoked, bit_depth: 16)

    assert_nil SourcePreference.select([ unavailable ], user: @user)
  end

  # Req 11.6 / 12.7: an available remote copy (active connection) participates in
  # selection while an unavailable one is skipped.
  test "skips unavailable remote copies and selects an available one" do
    prefer_highest_quality
    revoked = remote_library(status: :revoked)
    active = remote_library(status: :active)

    unavailable = build_song(library: revoked, bit_depth: 24)      # higher quality but unavailable
    available = build_song(library: active, bit_depth: 16)

    assert_equal available, SourcePreference.select([ unavailable, available ], user: @user)
  end

  # --- structural guarantees -------------------------------------------------

  # Req 12.6: selection is deterministic — the same inputs (in any order) always
  # yield the same Song.
  test "selection is deterministic and independent of input order" do
    prefer_highest_quality
    lib_a = create_local_library
    lib_b = create_local_library

    a = build_song(library: lib_a, bit_depth: 16)
    b = build_song(library: lib_b, bit_depth: 24)
    c = build_song(library: @own_library, bit_depth: nil)

    expected = SourcePreference.select([ a, b, c ], user: @user)
    5.times do
      assert_equal expected, SourcePreference.select([ a, b, c ].shuffle, user: @user)
    end
  end

  # The resolver accepts a Duplicate_Group directly (its member Songs).
  test "accepts a duplicate group as input" do
    prefer_own_server
    group = DuplicateGroup.create!(logical_track_key: "sp-test-key")

    own = build_song(library: @own_library, bit_depth: nil, duplicate_group: group)
    build_song(library: @other_local, bit_depth: 24, duplicate_group: group)

    assert_equal own, SourcePreference.select(group, user: @user)
  end

  # Req 11.2: an unset preference is treated as prefer_own_server.
  test "defaults to prefer_own_server when the user has no preference set" do
    assert_nil @user.settings["source_preference"]

    own = build_song(library: @own_library, bit_depth: nil)
    other = build_song(library: @other_local, bit_depth: 24)

    assert_equal own, SourcePreference.select([ other, own ], user: @user)
  end

  private

  def prefer_own_server
    @user.source_preference = "prefer_own_server"
  end

  def prefer_highest_quality
    @user.source_preference = "prefer_highest_quality"
  end

  def create_local_library
    @lib_counter ||= 0
    @lib_counter += 1
    Library.create!(
      name: "Local Library #{@lib_counter}",
      kind: :local,
      media_path: Rails.root.join("test", "fixtures", "files").to_s
    )
  end

  def remote_library(status: :active)
    @remote_counter ||= 0
    @remote_counter += 1
    connection = LibraryConnection.create!(
      user: @user,
      server_base_url: "https://host#{@remote_counter}.example",
      remote_library_id: @remote_counter,
      grant_token: "token#{@remote_counter}",
      status: status
    )
    Library.create!(name: "Remote Library #{@remote_counter}", kind: :remote, library_connection: connection)
  end

  def build_song(library:, bit_depth:, album: albums(:album1), artist: artists(:artist1), duplicate_group: nil)
    @counter += 1
    Song.create!(
      name: "sp_track_#{@counter}",
      file_path: "/tmp/sp_track_#{@counter}.flac",
      file_path_hash: "sp_hash_#{@counter}",
      md5_hash: "sp_md5_#{library.id}_#{@counter}",
      album: album,
      artist: artist,
      library: library,
      bit_depth: bit_depth,
      duplicate_group: duplicate_group
    )
  end
end
