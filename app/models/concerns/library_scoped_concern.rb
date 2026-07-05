# frozen_string_literal: true

# Shared behavior for content (Song/Album/Artist) that belongs to a Library.
#
# Every piece of content belongs to exactly one Library (Req 2.2). When content
# is created without an explicit library it falls back to the Default_Library,
# mirroring the pre-feature single-collection behavior (Req 1.7). This keeps the
# `library_id` NOT NULL association satisfied for callers that predate
# multi-library scoping.
module LibraryScopedConcern
  extend ActiveSupport::Concern

  included do
    belongs_to :library, optional: true

    before_validation :assign_default_library, if: -> { library_id.nil? }

    # Restrict a Song/Album/Artist query to the content of a single Library.
    # When `library` is nil — which is how a User with access to zero Libraries
    # is represented — this returns an empty relation so browsing, searching,
    # and listing yield no results (Req 3.2, 3.7).
    scope :in_library, ->(library) { library.present? ? where(library_id: library) : none }
  end

  private

  def assign_default_library
    self.library_id = Library.default&.id
  end
end
