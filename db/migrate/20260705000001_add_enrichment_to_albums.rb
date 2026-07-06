# frozen_string_literal: true

# Stores external enrichment for an Album gathered from a metadata provider
# (Open Library for audiobooks, setlist.fm for live recordings): the validated
# identity plus provider-specific details (author/publication year, or
# venue/event date/setlist verification). Serialized as JSON in a single text
# column so the schema stays provider-agnostic and no new tables are needed for
# the enrichment layer.
class AddEnrichmentToAlbums < ActiveRecord::Migration[8.1]
  def change
    add_column :albums, :enrichment, :text
  end
end
