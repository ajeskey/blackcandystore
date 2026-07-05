# frozen_string_literal: true

module Federation
  # Serves a remote redeeming Server the songs, albums, and artists of a local
  # library it is authorized to access (Req 6.1). Each action authorizes the
  # presented grant token against the requested library and then returns the
  # same JSON shape used for local browsing by reusing the existing jbuilder
  # index templates, scoped strictly to the authorized local library's content.
  class LibrariesController < BaseController
    def songs
      authorize_federation!(params[:library_id])

      records = Song.where(library_id: @library.id).includes(:artist, :album)
      @pagy, @songs = pagy(records)

      # `song_json_builder` consults `Current.user` only to resolve the
      # per-user favorite flag, which has no meaning for a cross-server request.
      # Pre-setting it avoids touching the (absent) session user.
      @songs.each { |song| song.is_favorited = false }

      render template: "songs/index", formats: :json
    end

    def albums
      authorize_federation!(params[:library_id])

      records = Album.where(library_id: @library.id).includes(:artist).with_attached_cover_image
      @pagy, @albums = pagy(records)

      render template: "albums/index", formats: :json
    end

    def artists
      authorize_federation!(params[:library_id])

      records = Artist.where(library_id: @library.id).with_attached_cover_image
      @pagy, @artists = pagy(records)

      render template: "artists/index", formats: :json
    end
  end
end
