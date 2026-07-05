json.call(library, :id, :name, :kind, :is_default, :scan_state)
json.active library.id == @active_library&.id
