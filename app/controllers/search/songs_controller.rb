# frozen_string_literal: true

class Search::SongsController < ApplicationController
  def index
    @pagy, @songs = pagy(scoped_to_active_library(Song.search(params[:query])).includes(:artist, :album))
  end
end
