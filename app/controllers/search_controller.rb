# frozen_string_literal: true

class SearchController < ApplicationController
  SEARCH_RESULT_MAX_AMOUNT = 10

  after_action :set_link_header, only: :index, if: :api_request?

  def index
    searched_albums = scoped_to_active_library(Album.search(params[:query])).includes(:artist).with_attached_cover_image
    searched_artists = scoped_to_active_library(Artist.search(params[:query])).with_attached_cover_image
    searched_playlists = Playlist.search(params[:query])
    searched_songs = scoped_to_active_library(Song.search(params[:query])).includes(:artist, :album)

    @albums = searched_albums.limit(SEARCH_RESULT_MAX_AMOUNT).load_async
    @is_all_albums = searched_albums.count <= SEARCH_RESULT_MAX_AMOUNT

    @artists = searched_artists.limit(SEARCH_RESULT_MAX_AMOUNT).load_async
    @is_all_artists = searched_artists.count <= SEARCH_RESULT_MAX_AMOUNT

    @playlists = searched_playlists.limit(SEARCH_RESULT_MAX_AMOUNT).load_async
    @is_all_playlists = searched_playlists.count <= SEARCH_RESULT_MAX_AMOUNT

    @songs = searched_songs.limit(SEARCH_RESULT_MAX_AMOUNT).load_async
    @is_all_songs = searched_songs.count <= SEARCH_RESULT_MAX_AMOUNT
  end

  private

  def set_link_header
    links = []
    links << %(<#{search_albums_url(query: params[:query])}>; rel="search-albums") unless @is_all_albums
    links << %(<#{search_artists_url(query: params[:query])}>; rel="search-artists") unless @is_all_artists
    links << %(<#{search_playlists_url(query: params[:query])}>; rel="search-playlists") unless @is_all_playlists
    links << %(<#{search_songs_url(query: params[:query])}>; rel="search-songs") unless @is_all_songs

    response.headers["Link"] = links.join(", ") if links.any?
  end
end
