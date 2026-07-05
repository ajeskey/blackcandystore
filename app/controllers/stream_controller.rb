# frozen_string_literal: true

class StreamController < ApplicationController
  include SidecarStreamAccess

  before_action :find_stream

  def new
    if thruster_sendfile?
      send_file @stream.file_path
      return
    end

    # Use Rack::File to support HTTP range on local without thruster. see https://github.com/rails/rails/issues/32193
    Rack::Files.new(nil).serving(request, @stream.file_path).tap do |(status, headers, body)|
      self.status = status
      self.response_body = body

      headers.each { |name, value| response.headers[name] = value }

      response.headers["Content-Type"] = Mime[@stream.format]
      response.headers["Content-Disposition"] = "attachment"
    end
  end

  private

  def find_stream
    @stream = Stream.new(Song.find(params[:song_id]))
  end

  def thruster_sendfile?
    Rails.configuration.action_dispatch.x_sendfile_header == "X-Sendfile"
  end
end
