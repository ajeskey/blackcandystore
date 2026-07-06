# frozen_string_literal: true

# RadioStationsController is the API_Surface for configuring, controlling, and
# authenticating a Radio_Station (Req 1, 9, 10, 11). Every action responds to
# BOTH `format.html` (the Turbo Web_UI, task 14.1) and `format.json` (a
# client-agnostic representation that does not depend on server-rendered HTML,
# Req 9.4), and applies IDENTICAL authorization to both paths (Req 9.5) by
# delegating every authority decision to the pure seams — `AuthorizationPolicy`
# for mutation authority (Req 1.8) and `StationLifecycleService` for the
# start/stop lifecycle and its owner/admin + concurrency rules (Req 10).
#
# Responsibilities:
#   * CRUD over a Radio_Station and its Station_Source_Criteria (Req 1.1, 1.2,
#     1.5, 1.7), rejecting a criteria set that selects no authorized Song via the
#     model's validation (Req 1.3, 1.9) and an invalid name (Req 1.6).
#   * Start/stop lifecycle (Req 10.1, 10.2, 10.3, 10.6) through
#     `StationLifecycleService`.
#   * Stream_Token rotate/revoke (Req 11.5) through `StreamTokenService`, with
#     the freshly minted plaintext returned exactly once so it can be embedded
#     in the Stream_Endpoint URL.
#   * Exposing the Stream_Endpoint URL for every station regardless of state
#     (Req 9.6); audio is only served there while the station is `started`, which
#     the Stream_Endpoint controller (task 9.4) enforces.
#
# A create/modify/delete/start/stop by a User who is neither the owner nor an
# Admin is rejected with an authorization error (Req 1.8, 10.3): mutation actions
# are gated by `authorize_owner_or_admin!` and the lifecycle actions surface the
# service's `:unauthorized` result as `BlackCandy::Forbidden`.
class RadioStationsController < ApplicationController
  before_action :find_radio_station, only: [ :show, :edit, :update, :destroy, :start, :stop, :rotate_stream_token, :revoke_stream_token ]
  before_action :authorize_owner_or_admin!, only: [ :show, :edit, :update, :destroy, :rotate_stream_token, :revoke_stream_token ]

  helper_method :radio_stream_endpoint_url

  def index
    @radio_stations = RadioStation.where(user: Current.user).order(:name)

    respond_to do |format|
      format.html
      format.json
    end
  end

  def show
    respond_to do |format|
      format.html
      format.json
    end
  end

  def new
    @radio_station = RadioStation.new
  end

  def edit
  end

  def create
    @radio_station = RadioStation.new(radio_station_params)
    @radio_station.user = Current.user

    ActiveRecord::Base.transaction do
      assign_criteria(@radio_station)
      @radio_station.save!
    end

    respond_to do |format|
      format.html { redirect_to @radio_station, notice: t("notice.created") }
      format.json { render :show, status: :created }
    end
  end

  def update
    ActiveRecord::Base.transaction do
      @radio_station.assign_attributes(radio_station_params)
      assign_criteria(@radio_station)
      @radio_station.save!
    end

    respond_to do |format|
      format.html { redirect_to @radio_station, notice: t("notice.updated") }
      format.json { render :show }
    end
  end

  def destroy
    # Stopping first ends the Shared_Stream before the configuration is removed
    # (Req 1.7); the actor has already passed the owner/admin gate.
    StationLifecycleService.new(@radio_station).stop(actor: Current.user)
    @radio_station.destroy!

    respond_to do |format|
      format.html { redirect_to radio_stations_path, notice: t("notice.deleted") }
      format.json { head :no_content }
    end
  end

  def start
    result = StationLifecycleService.new(@radio_station).start(actor: Current.user)
    render_lifecycle_result(result)
  end

  def stop
    result = StationLifecycleService.new(@radio_station).stop(actor: Current.user)
    render_lifecycle_result(result)
  end

  def rotate_stream_token
    # The plaintext is returned in-memory exactly once (via `#token`) so the
    # owner can embed it in the Stream_Endpoint URL; only its keyed digest is
    # persisted (Req 11.5).
    @stream_token = StreamTokenService.rotate_radio_token(@radio_station)

    respond_to do |format|
      format.html { redirect_to @radio_station, notice: t("notice.updated") }
      format.json { render :stream_token }
    end
  end

  def revoke_stream_token
    StreamTokenService.revoke_radio_token(@radio_station)

    respond_to do |format|
      format.html { redirect_to @radio_station, notice: t("notice.updated") }
      format.json { render :show }
    end
  end

  private

  def find_radio_station
    @radio_station = RadioStation.find(params[:id])
  end

  # The Stream_Endpoint URL exposed for a station regardless of its `started` or
  # `stopped` state (Req 9.6). The URL always exists; audio is served there only
  # while the station is `started`, which the Stream_Endpoint controller (task
  # 9.4) enforces. Built as an absolute URL from the request origin so a
  # client-agnostic representation can be handed to a generic MP3 client; the
  # `/radio/:id/stream.mp3` shape matches the design's documented endpoint and is
  # routed by task 8.6.
  def radio_stream_endpoint_url(station)
    "#{request.base_url}/radio/#{station.id}/stream.mp3"
  end

  # Identical owner/admin authority for the HTML and JSON paths (Req 1.8, 9.5),
  # delegated to the pure `AuthorizationPolicy` seam so there is a single
  # definition of "owner or admin". A non-owner non-admin is rejected with an
  # authorization error before any state is read or changed.
  def authorize_owner_or_admin!
    raise BlackCandy::Forbidden unless AuthorizationPolicy.mutation_authorized?(Current.user, @radio_station.user_id)
  end

  # The station's own attributes. `criteria` is submitted under the same
  # `radio_station` namespace but is handled separately by `assign_criteria`
  # (it maps to the `station_source_criteria` association, not a column), so it
  # is permitted here purely to avoid tripping strict unpermitted-parameter
  # handling and then excluded from the attributes assigned to the model.
  def radio_station_params
    params.require(:radio_station)
          .permit(:name, :stream_visibility, :listener_limit, criteria: [ :criterion_type, :artist_id, :song_id, :genre ])
          .except(:criteria)
  end

  # Replaces the station's Station_Source_Criteria from the submitted `criteria`
  # array when one is provided (Req 1.2, 1.5). Assigning the collection on a
  # persisted station is immediate, so both create and update run inside a
  # transaction: if the resulting eligible-song set is empty the model's
  # validation raises `RecordInvalid`, the transaction rolls back, and the
  # existing criteria are left unchanged (Req 1.3, 1.9). When no `criteria` key
  # is present the existing criteria are preserved.
  def assign_criteria(station)
    return unless params[:radio_station].key?(:criteria)

    station.station_source_criteria = criteria_attributes.map do |attributes|
      StationSourceCriterion.new(attributes)
    end
  end

  def criteria_attributes
    Array(params[:radio_station][:criteria]).map do |criterion|
      criterion.permit(:criterion_type, :artist_id, :song_id, :genre)
    end
  end

  # Translates a `StationLifecycleService` Result into an HTTP response,
  # identically for HTML and JSON (Req 9.5). An `:unauthorized` result becomes an
  # authorization error (Req 10.3); an `:at_capacity` result becomes a capacity
  # response and leaves the station's state unchanged (Req 10.6); a
  # `:broadcaster_unavailable` result becomes a service-unavailable response and
  # likewise leaves the station's state unchanged (the Broadcaster could not be
  # reached, so the broadcast never started); a success renders the station's
  # current state.
  def render_lifecycle_result(result)
    raise BlackCandy::Forbidden if result.error == BroadcastLifecycle::ERROR_UNAUTHORIZED

    if result.error == BroadcastLifecycle::ERROR_AT_CAPACITY
      return render_at_capacity
    end

    if result.error == BroadcastLifecycle::ERROR_BROADCASTER_UNAVAILABLE
      return render_broadcaster_unavailable
    end

    respond_to do |format|
      format.html { redirect_to @radio_station, notice: t("notice.updated") }
      format.json { render :show }
    end
  end

  def render_at_capacity
    message = t("error.stream_at_capacity", default: "The maximum number of concurrent streams has been reached")

    respond_to do |format|
      format.json { render_json_error("AtCapacity", message, :service_unavailable) }
      format.html { redirect_to radio_stations_path, alert: message }
    end
  end

  def render_broadcaster_unavailable
    message = t("error.broadcaster_unavailable", default: "The streaming service is currently unavailable")

    respond_to do |format|
      format.json { render_json_error("BroadcasterUnavailable", message, :service_unavailable) }
      format.html { redirect_to radio_stations_path, alert: message }
    end
  end
end
