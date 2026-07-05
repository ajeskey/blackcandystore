# frozen_string_literal: true

module Federation
  # Liveness/health probe used by a redeeming Server to check reachability
  # within a timeout budget (design: Cross-Server HTTP API Contract). It answers
  # 200 without touching any library content, so a redeeming Server can confirm
  # the hosting Server is up before or independently of any specific library
  # request.
  class PingController < BaseController
    def show
      head :ok
    end
  end
end
