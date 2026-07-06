json.call(radio_station, :id, :name, :state, :stream_visibility, :listener_limit, :user_id, :created_at, :updated_at)

# The Stream_Endpoint URL is exposed for every station regardless of state
# (Req 9.6); audio is only served there while the station is `started`.
json.stream_endpoint_url radio_stream_endpoint_url(radio_station)

json.station_source_criteria radio_station.station_source_criteria do |criterion|
  json.call(criterion, :id, :criterion_type, :artist_id, :song_id, :genre)
end
