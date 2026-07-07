# frozen_string_literal: true

# ContinueListeningController exposes the current User's Continue_Listening_List
# as a client-agnostic representation for App_Players (Req 8.1, 8.2). The Home
# page renders the same list server-side (task 8), so this controller is
# concerned only with the JSON surface.
#
# It is a singular resource (the list always belongs to Current.user), so the
# single action is #show. Authentication is already handled by the
# Authentication concern in ApplicationController before this action runs, and
# the list is read exclusively through Current.user's own records (Req 7.3). An
# empty result is a valid empty list, returned without error (Req 4.7).
class ContinueListeningController < ApplicationController
  def show
    @positions = Playback::ContinueListeningQuery.new(Current.user).call

    respond_to do |format|
      format.json
    end
  end
end
