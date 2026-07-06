# Client-agnostic join-page preview for an opened Share_Link (Req 9.4). Confirms
# the session a Guest is about to join and whether it still accepts new joins
# (`joinable`), WITHOUT admitting the Guest or issuing a Guest_Token — that
# happens on POST. No library contents or download/file-path data are exposed to
# an un-admitted visitor (Req 5.7).
json.joinable @joinable

json.session do
  json.id @session.id
  json.type @session.model_name.element
  json.state @session.state
  json.shared_library_ids @session.shared_library_ids
end
