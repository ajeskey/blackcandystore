# frozen_string_literal: true

module Playback
  # Pure seam (no I/O) that decides which side of a reconciliation wins when a
  # Playback_Position exists both on the Server and on a Client.
  #
  # The rule is "most-recent update wins": whichever side has the later
  # last-updated time is chosen. Ties resolve to :server so the authoritative
  # record wins (Req 6.5), and a missing client timestamp also resolves to
  # :server. The Web_Player mirrors this exact rule in JS for the
  # localStorage-vs-server decision (Req 6.3); the Server applies it when a
  # Client presents a position with a client timestamp (Req 6.5).
  module PositionReconciler
    module_function

    # Choose the more-recently-updated side. Returns :server or :client.
    def choose(server_updated_at:, client_updated_at:)
      return :server if client_updated_at.nil?
      return :client if server_updated_at.nil?

      client_updated_at > server_updated_at ? :client : :server
    end
  end
end
