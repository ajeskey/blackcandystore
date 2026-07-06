json.partial! "radio_stations/radio_station", radio_station: @radio_station

# The freshly minted plaintext Stream_Token is returned exactly once so the
# owner can embed it in the Stream_Endpoint URL; only its keyed digest is
# persisted (Req 11.5). A subsequent read of the station never re-exposes it.
json.stream_token do
  json.status @stream_token.status
  json.token @stream_token.token
  json.stream_endpoint_url "#{radio_stream_endpoint_url(@radio_station)}?token=#{@stream_token.token}"
end
