# Client-agnostic admission representation (Req 9.4). The plaintext Guest_Token
# is returned exactly once here so the client can present it as a non-cookie
# Bearer credential on later guest requests (Req 5.1, 5.13, 9.2); only its keyed
# digest is persisted (Req 8.7). No download/export/file-path data is exposed to
# the Guest (Req 5.7).
json.guest_token @guest_token

json.guest do
  json.id @guest.id
  json.display_name @guest.display_name
end

json.session do
  json.id @session.id
  json.type @session.model_name.element
  json.shared_playlist_id @session.shared_playlist&.id
  json.shared_library_ids @session.shared_library_ids
end

# For a Co_Listen_Session, expose the per-participant guest-derived Stream_Token
# and the Stream_Endpoint URL it is embedded in (Req 7.4, 11.8, 11.9) so this
# participant can tune into the Shared_Stream on their own device. The token is
# scoped to this session + its shared Libraries and stops authorizing when the
# Guest's access ends. A Party_Session has no Stream_Endpoint (Req 9.7), so
# these keys are present only for a co-listen admission.
if @stream_endpoint_url
  json.stream_token @stream_token
  json.stream_endpoint_url @stream_endpoint_url
end
