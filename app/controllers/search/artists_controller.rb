# frozen_string_literal: true

class Search::ArtistsController < ApplicationController
  def index
    @pagy, @artists = pagy(scoped_to_active_library(Artist.search(params[:query])).with_attached_cover_image)
  end
end
