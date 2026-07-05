# frozen_string_literal: true

module SongHelper
  def song_json_builder(song)
    transcode = need_transcode?(song)
    stream_url = new_stream_url(song_id: song.id)
    transcoded_stream_url = new_transcoded_stream_url(song_id: song.id)

    # Resolve the Song's Stream_Source and Resolved_Stream_Path at the edge so
    # the Web_Player and App_Player never need library-specific logic (Req 8.3).
    # The legacy `url` field is preserved unchanged for backward compatibility;
    # the resolver adds the source classification and a same-origin resolved
    # path alongside it (Req 8.10).
    resolved_stream = PathResolver.new.resolve_stream(song, user: Current.user, transcode: transcode)

    Jbuilder.new do |json|
      json.call(song, :id, :name, :duration, :album_id, :artist_id)
      json.url transcode ? transcoded_stream_url : stream_url
      json.stream_source resolved_stream[:stream_source]
      json.resolved_stream_path resolved_stream[:resolved_stream_path]
      json.available resolved_stream[:available]
      json.album_name song.album.name
      json.artist_name song.artist.name
      json.is_favorited song.is_favorited.nil? ? Current.user.favorited?(song) : song.is_favorited
      json.format transcode ? Stream::TRANSCODE_FORMAT : song.format
      json.album_image_urls do
        json.small URI.join(root_url, cover_image_url_for(song.album, size: :small))
        json.medium URI.join(root_url, cover_image_url_for(song.album, size: :medium))
        json.large URI.join(root_url, cover_image_url_for(song.album, size: :large))
      end
    end
  end
end
