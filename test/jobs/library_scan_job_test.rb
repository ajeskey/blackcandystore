# frozen_string_literal: true

require "test_helper"

class LibraryScanJobTest < ActiveJob::TestCase
  setup do
    @library = libraries(:secondary_library)
  end

  test "should associate all scanned content with the given library" do
    LibraryScanJob.perform_now(@library.id)

    assert_equal 3, @library.artists.count
    assert_equal 4, @library.albums.count
    assert_equal 9, @library.songs.count

    assert @library.songs.all? { |song| song.library_id == @library.id }
    assert @library.albums.all? { |album| album.library_id == @library.id }
    assert @library.artists.all? { |artist| artist.library_id == @library.id }
  end

  test "should report the library as idle after a successful scan" do
    @library.update!(scan_state: :syncing)

    LibraryScanJob.perform_now(@library.id)

    assert @library.reload.idle?
  end

  test "should report the library as syncing while scanning" do
    states = []

    Media.stub(:clean_up, ->(*) { states << Library.find(@library.id).scan_state }) do
      LibraryScanJob.perform_now(@library.id)
    end

    assert_includes states, "syncing"
  end

  test "should record a scan failure when the scan terminates before completing" do
    MediaFile.stub(:file_paths, ->(*) { raise "boom" }) do
      assert_raises(RuntimeError) do
        LibraryScanJob.perform_now(@library.id)
      end
    end

    assert @library.reload.failed?
  end

  test "should broadcast scan state changes" do
    assert_broadcasts("media_sync", 2) do
      LibraryScanJob.perform_now(@library.id)
    end
  end

  test "should not toggle the global media syncing cache flag" do
    refute Media.syncing?

    LibraryScanJob.perform_now(@library.id)

    refute Media.syncing?
  end

  test "should not remove songs that already belong to the library on a re-scan" do
    LibraryScanJob.perform_now(@library.id)
    song_ids = @library.songs.ids.sort

    LibraryScanJob.perform_now(@library.id)

    assert_equal song_ids, @library.reload.songs.ids.sort
  end
end
