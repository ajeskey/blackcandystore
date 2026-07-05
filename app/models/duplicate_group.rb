# frozen_string_literal: true

# A Duplicate_Group represents one Logical_Track: the set of Songs across
# libraries/servers recognized as the same content. Source_Preference selects
# exactly one playable Song from the group for a user (Req 12.3, 12.6).
class DuplicateGroup < ApplicationRecord
  has_many :songs, dependent: :nullify
end
