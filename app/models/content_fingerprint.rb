# frozen_string_literal: true

# Per-song content signature compared by the Deduplicator to decide whether two
# Songs represent the same content (Req 12.1, 12.2). Fingerprint computation is
# handled by the Deduplicator (task 18.2); this model only persists the values.
class ContentFingerprint < ApplicationRecord
  belongs_to :song
end
