# frozen_string_literal: true

require "test_helper"

class ContentClassifierTest < ActiveSupport::TestCase
  test "classifies audiobook genres as audiobook" do
    assert_equal :audiobook, ContentClassifier.classify(genre: "Audiobook")
    assert_equal :audiobook, ContentClassifier.classify(genre: "audio book")
    assert_equal :audiobook, ContentClassifier.classify(genre: "Spoken Word")
  end

  test "classifies live genres and live-style names as live" do
    assert_equal :live, ContentClassifier.classify(genre: "Live")
    assert_equal :live, ContentClassifier.classify(genre: "Concert")
    assert_equal :live, ContentClassifier.classify(name: "Live at Wembley")
    assert_equal :live, ContentClassifier.classify(name: "Reptile (Live)")
    assert_equal :live, ContentClassifier.classify(name: "Live in Tokyo 1994")
  end

  test "defaults to music for ordinary tags" do
    assert_equal :music, ContentClassifier.classify(genre: "Rock", name: "Nevermind")
    assert_equal :music, ContentClassifier.classify(genre: nil, name: nil)
  end

  test "audiobook genre wins over a live-looking name" do
    assert_equal :audiobook, ContentClassifier.classify(genre: "Audiobook", name: "Live and Let Die")
  end

  test "classify_album reads tags off the album" do
    album = albums(:album1)
    album.update!(genre: "Audiobook")

    assert_equal :audiobook, ContentClassifier.classify_album(album)
    assert ContentClassifier.audiobook?(album)
    assert_not ContentClassifier.live?(album)
  end

  test "nil album is music" do
    assert_equal :music, ContentClassifier.classify_album(nil)
  end
end
