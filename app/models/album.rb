# frozen_string_literal: true

class Album < ApplicationRecord
  UNKNOWN_NAME = "Unknown Album"

  include SearchableConcern
  include ImageableConcern
  include FilterableConcern
  include SortableConcern
  include LibraryScopedConcern

  after_initialize :set_default_name, if: :new_record?

  validates :name, presence: true

  has_many :songs, -> { order(:discnum, :tracknum) }, inverse_of: :album, dependent: :destroy
  belongs_to :artist, touch: true

  # External enrichment gathered from a metadata provider (Open Library for
  # audiobooks, setlist.fm for live recordings). Provider-agnostic JSON so any
  # provider can persist its validated identity and details here.
  serialize :enrichment, type: Hash, coder: JSON

  search_by :name, associations: { artist: :name }

  filter_by :year, :genre

  sort_by :name, :year, :created_at
  sort_by_associations artist: :name

  scope :lack_metadata, -> {
    includes(:artist, :cover_image_attachment)
      .where(cover_image_attachment: { id: nil })
      .where.not(name: Album::UNKNOWN_NAME)
      .where.not(artists: { name: Artist::UNKNOWN_NAME })
  }

  def unknown?
    name == UNKNOWN_NAME
  end

  # The content kind derived from this album's tags (:music, :audiobook, :live).
  def content_type
    ContentClassifier.classify_album(self)
  end

  def audiobook?
    content_type == ContentClassifier::AUDIOBOOK
  end

  def live?
    content_type == ContentClassifier::LIVE
  end

  # True once a provider has stored enrichment for this album.
  def enriched?
    enrichment.present?
  end

  private

  def set_default_name
    self.name ||= UNKNOWN_NAME
  end
end
