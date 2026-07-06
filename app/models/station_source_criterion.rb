# frozen_string_literal: true

# Station_Source_Criteria define which Songs are eligible for a Radio_Station's
# program. Any combination of Artists, specific Songs, and Genres is allowed
# (Req 1.2). Each row carries a single criterion of one `criterion_type`
# (`artist`/`song`/`genre`) with the matching value column populated:
# `artist_id` for `artist`, `song_id` for `song`, and the free-text `genre`
# value (matching the `genre` column on albums) for `genre`.
class StationSourceCriterion < ApplicationRecord
  # The default inflector would derive `station_source_criterions`; the table is
  # the Latin plural `station_source_criteria`.
  self.table_name = "station_source_criteria"

  belongs_to :radio_station
  # Populated only for an `artist`/`song` criterion respectively; nil otherwise.
  belongs_to :artist, optional: true
  belongs_to :song, optional: true

  # One of `artist`, `song`, or `genre` (Req 1.2). Prefixed so its generated
  # scopes/predicates (`type_artist`, `type_song?`, ...) never collide with the
  # `artist`/`song` associations above.
  enum :criterion_type, { artist: "artist", song: "song", genre: "genre" }, prefix: :type

  validates :criterion_type, presence: true
end
