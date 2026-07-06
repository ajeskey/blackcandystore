# frozen_string_literal: true

# Radio_Station is a User-defined configuration of Station_Source_Criteria
# (Artists, specific Songs, and/or Genres) from which the Server assembles a
# continuous, always-on Shared_Stream (Req 1.1, 1.2).
#
# The eligible-song set is never persisted: it is derived at query time from the
# station's criteria intersected with the songs in the owner's authorized
# libraries (Req 1.4), so it always reflects the current criteria (Req 1.5) and
# the owner's current authorization. A create or update is rejected when that
# derived set is empty (Req 1.3, 1.9).
class RadioStation < ApplicationRecord
  # Owner of the station; authority for mutation/lifecycle (Req 1.1, 1.8).
  belongs_to :user

  # Station_Source_Criteria define which Songs are eligible (Req 1.2). Removing a
  # station removes its criteria. `class_name` is given explicitly because the
  # default inflector singularizes "criteria" to "criterium".
  has_many :station_source_criteria, class_name: "StationSourceCriterion", dependent: :destroy
  # The keyed-digest Stream_Token that authorizes an `authenticated` station's
  # Stream_Endpoint (Req 11.5). Optional until issued.
  has_one :stream_token, dependent: :destroy

  # Station_State lifecycle: `stopped` (not broadcasting) or `started`
  # (broadcasting a Shared_Stream). Defaults to `stopped` (Req 10.1, 10.2).
  enum :state, { stopped: "stopped", started: "started" }, default: :stopped

  # Stream_Visibility: `authenticated` (requires a Stream_Token or an authorized
  # account) or `public` (served without credentials). Defaults to
  # `authenticated` (Req 11.1). Prefixed to avoid generating a bare `public`
  # scope that would collide with Ruby's `Module#public`.
  enum :stream_visibility, { authenticated: "authenticated", public: "public" }, default: :authenticated, prefix: :visibility

  # A submitted name is trimmed of surrounding whitespace before validation so a
  # whitespace-only name is treated as blank (Req 1.6, Property 3).
  normalizes :name, with: ->(name) { name.to_s.strip }

  # Name is accepted iff its trimmed length is between 1 and 255 inclusive; an
  # empty, whitespace-only, or over-255 name is rejected (Req 1.1, 1.6).
  validates :name, presence: true, length: { maximum: 255 }

  # A station is accepted iff its Station_Source_Criteria select at least one
  # Song the owning User is authorized to access (Req 1.3, 1.9, Property 2).
  validate :criteria_must_select_authorized_song

  # The Songs eligible for this station's program: the Songs matching the
  # Station_Source_Criteria intersected with the Songs in the owning User's
  # authorized libraries (Req 1.4). Recomputed from the current criteria on every
  # call, so a criteria change is reflected immediately (Req 1.5, Property 1).
  def eligible_songs
    authorized_library_ids = user&.authorized_library_ids || []
    return Song.none if authorized_library_ids.empty?

    matching_ids = matching_song_ids
    return Song.none if matching_ids.empty?

    Song.where(library_id: authorized_library_ids, id: matching_ids)
  end

  private

  # Song ids matching the station's criteria, unioned across every criterion
  # type. Reads criterion values from the in-memory association so it works for
  # an unsaved station with freshly built criteria as well as a persisted one.
  def matching_song_ids
    artist_ids = criterion_values("artist", :artist_id)
    song_ids = criterion_values("song", :song_id)
    genres = criterion_values("genre", :genre)

    relations = []
    relations << Song.where(artist_id: artist_ids) if artist_ids.any?
    relations << Song.where(id: song_ids) if song_ids.any?
    relations << Song.joins(:album).where(albums: { genre: genres }) if genres.any?
    return [] if relations.empty?

    relations.flat_map(&:ids).uniq
  end

  # The non-nil values of `attribute` across every criterion of `type`.
  def criterion_values(type, attribute)
    station_source_criteria.select { |criterion| criterion.criterion_type == type }
                           .map { |criterion| criterion.public_send(attribute) }
                           .compact
  end

  def criteria_must_select_authorized_song
    return if eligible_songs.exists?

    errors.add(:base, "criteria select no playable songs")
  end
end
