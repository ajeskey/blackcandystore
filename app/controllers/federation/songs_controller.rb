# frozen_string_literal: true

module Federation
  # Streams the audio bytes of a song in an authorized local library to a remote
  # redeeming Server (Req 6.2). Mirrors the local StreamController serving logic
  # (HTTP range support via Rack::Files, or X-Sendfile when Thruster is enabled)
  # but scopes the song strictly to the authorized local library so only that
  # library's content can be reached.
  class SongsController < BaseController
    def stream
      authorize_federation!(params[:library_id])

      song = Song.where(library_id: @library.id).find(params[:song_id])
      stream = Stream.new(song)

      if thruster_sendfile?
        send_file stream.file_path
        return
      end

      # Use Rack::Files to support HTTP range requests without Thruster.
      # See https://github.com/rails/rails/issues/32193
      Rack::Files.new(nil).serving(request, stream.file_path).tap do |(status, headers, body)|
        self.status = status
        self.response_body = body

        headers.each { |name, value| response.headers[name] = value }

        response.headers["Content-Type"] = Mime[stream.format]
        response.headers["Content-Disposition"] = "attachment"
      end
    end

    private

    def thruster_sendfile?
      Rails.configuration.action_dispatch.x_sendfile_header == "X-Sendfile"
    end
  end
end
