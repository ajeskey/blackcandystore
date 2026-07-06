# frozen_string_literal: true

require "httparty"

# Broadcaster is the thin Rails-side seam that controls the out-of-process
# **Broadcaster** service — the continuous-MP3 assembly + Icecast-style fan-out
# sibling to the playback sidecar (see the design's "Streaming / Broadcaster
# Architecture Decision"). Rails owns all authoritative domain state, sequencing
# decisions, scheduling, and authorization; this module only translates a
# control intent ("start / stop / advance / inspect a broadcast") into a local
# HTTP call to the Broadcaster and maps its responses back into domain outcomes.
#
# It deliberately mirrors PlaybackSidecar::Client: an injectable client seam
# reached over loopback HTTP, short timeouts because the Broadcaster is local,
# and transport failures translated into a domain error (`Unavailable`) rather
# than leaking a raw `Net::*`/`SocketError`. The continuous encoding and byte
# fan-out live entirely in the Broadcaster and are exercised only by
# integration/smoke tests — never by Ruby.
#
# Rails ⇄ Broadcaster control contract (loopback HTTP, JSON):
#
#   POST   /broadcasts            start a broadcast for a station/session id
#   DELETE /broadcasts/:id        stop and tear down a broadcast
#   POST   /broadcasts/:id/next   provide the next resolved source (or continuity)
#   GET    /broadcasts/:id/status current encode position, listener count, uptime
#
# This task (9.2) implements the control client only. Wiring the lifecycle
# services to it (start/stop/next driven by ProgramSequencer / ResumeStreamsJob)
# is task 9.3, and the public reverse-proxy stream endpoint is task 9.4.
module Broadcaster
  # ENV var holding the Broadcaster's base URL. Defaults to a loopback address
  # so a co-located Broadcaster works with zero configuration, mirroring the
  # PLAYBACK_SIDECAR_URL convention.
  BROADCASTER_URL_ENV = "BROADCASTER_URL"
  DEFAULT_BROADCASTER_URL = "http://127.0.0.1:9340"

  # Control-plane endpoints on the Broadcaster.
  BROADCASTS_PATH = "/broadcasts"

  # Loopback fan-out (data-plane) endpoint prefix. `GET
  # /internal/broadcasts/:id/listen` streams the broadcast's continuous MP3
  # bytes from the *current* encode position (Req 2.4, 3.2, 7.4, 7.6). It is
  # bound to loopback only; the public Stream_Endpoint (StreamEndpointController)
  # reverse-proxies this after authorizing the connect, so there is a single
  # authenticated public surface and the Broadcaster stays private.
  INTERNAL_BROADCASTS_PATH = "/internal/broadcasts"

  # How long (seconds) to wait on the local Broadcaster before treating a control
  # call as failed. The Broadcaster is local, so this is deliberately short.
  CONTROL_TIMEOUT = 5

  # Raised when the Broadcaster cannot be reached or answers with a non-success
  # response. Translated by the caller into a control failure so the lifecycle
  # state machine never sees a raw transport error. Mirrors
  # PlaybackSidecar::Unavailable.
  class Unavailable < StandardError; end

  # Talks to the Broadcaster over loopback HTTP. Each method issues one JSON
  # control call, returns the parsed acknowledgement on success, and raises
  # Unavailable on any transport failure or non-success response.
  #
  # The underlying HTTP transport is injectable (`http:`) so tests can drive the
  # client with an in-memory fake instead of real sockets or webmock; it must
  # respond to `post`, `delete`, and `get` like HTTParty.
  class Client
    def initialize(base_url: Broadcaster.broadcaster_url, http: HTTParty)
      @base_url = base_url.to_s.chomp("/")
      @http = http
    end

    # Start a broadcast for a station/session.
    #
    # @param broadcast_id [String, Integer] the caller's stable id for the
    #   broadcast (e.g. "radio_station:42" / "co_listen_session:7"); the
    #   Broadcaster keys its internal stream handle by this id
    # @param kind [String] "radio" or "co_listen" — which broadcast flavor
    # @param source [Hash, nil] the initial resolved source to begin encoding
    #   (song path + signed stream token, or a continuity directive)
    # @return [Hash] the parsed acknowledgement, including the internal stream handle
    def start_broadcast(broadcast_id:, kind: nil, source: nil)
      post(
        BROADCASTS_PATH,
        { broadcast_id: broadcast_id, kind: kind, source: source }
      )
    end

    # Stop and tear down a broadcast (Req 10.2, 12.1). Idempotent from the
    # caller's perspective: a Broadcaster that has already forgotten the
    # broadcast simply acknowledges.
    #
    # @param broadcast_id [String, Integer] the broadcast to end
    # @return [Hash] the parsed acknowledgement
    def stop_broadcast(broadcast_id)
      delete("#{BROADCASTS_PATH}/#{broadcast_id}")
    end

    # Provide the next resolved source for a running broadcast — driven by
    # ProgramSequencer decisions (Req 2.2). `source` is either a resolved song
    # (path + signed stream token) or a continuity directive (Req 2.5) when
    # nothing is currently resolvable.
    #
    # @param broadcast_id [String, Integer] the broadcast to advance
    # @param source [Hash] the next resolved source or continuity directive
    # @return [Hash] the parsed acknowledgement
    def next_source(broadcast_id, source:)
      post("#{BROADCASTS_PATH}/#{broadcast_id}/next", { source: source })
    end

    # Fetch a broadcast's current status: encode position, listener count, and
    # uptime (used for join decisions and Listener_Limit accounting).
    #
    # @param broadcast_id [String, Integer] the broadcast to inspect
    # @return [Hash] the parsed status document
    def status(broadcast_id)
      get("#{BROADCASTS_PATH}/#{broadcast_id}/status")
    end

    # Open the broadcast's loopback MP3 fan-out and yield each byte fragment as
    # it arrives, so the caller (the public Stream_Endpoint) can reverse-proxy a
    # continuous `audio/mpeg` stream to a Listener from the current encode
    # position (Req 2.4, 3.2, 7.4, 7.6). This is a long-lived streaming read, so
    # — unlike the control calls — it sets no read timeout (only an open timeout
    # to bound the initial connect). Any failure to reach the fan-out is
    # translated into `Unavailable`, exactly like the control path, so the
    # caller can surface a 503 rather than leaking a raw transport error.
    #
    # @param broadcast_id [String, Integer] the broadcast to listen to
    # @yieldparam fragment [String] a chunk of MP3 bytes from the current position
    # @return [void]
    def listen(broadcast_id, &block)
      url = "#{@base_url}#{INTERNAL_BROADCASTS_PATH}/#{broadcast_id}/listen"

      @http.get(
        url,
        {
          headers: { "Accept" => "audio/mpeg" },
          stream_body: true,
          open_timeout: CONTROL_TIMEOUT
        },
        &block
      )
    rescue Net::OpenTimeout, Net::ReadTimeout, ::Timeout::Error => e
      raise Unavailable, "broadcaster fan-out did not connect within #{CONTROL_TIMEOUT}s: #{e.message}"
    rescue SocketError, Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH,
      Errno::ENETUNREACH, OpenSSL::SSL::SSLError, HTTParty::Error => e
      raise Unavailable, "broadcaster fan-out is unreachable: #{e.message}"
    end

    private

    def post(path, body)
      request(:post, path, body: body.to_json)
    end

    def delete(path)
      request(:delete, path)
    end

    def get(path)
      request(:get, path)
    end

    # Issue one control call and translate the outcome into a domain result.
    # Any transport failure or non-success response becomes Unavailable so the
    # lifecycle state machine only ever sees a domain error.
    def request(verb, path, body: nil)
      options = {
        headers: { "Content-Type" => "application/json", "Accept" => "application/json" },
        open_timeout: CONTROL_TIMEOUT,
        read_timeout: CONTROL_TIMEOUT
      }
      options[:body] = body unless body.nil?

      response = @http.public_send(verb, "#{@base_url}#{path}", options)

      code = response.code.to_i
      unless code.between?(200, 299)
        raise Unavailable, "broadcaster returned HTTP #{code}"
      end

      parse(response.body)
    rescue Net::OpenTimeout, Net::ReadTimeout, ::Timeout::Error => e
      raise Unavailable, "broadcaster did not respond within #{CONTROL_TIMEOUT}s: #{e.message}"
    rescue SocketError, Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH,
      Errno::ENETUNREACH, OpenSSL::SSL::SSLError, HTTParty::Error => e
      raise Unavailable, "broadcaster is unreachable: #{e.message}"
    end

    def parse(body)
      return {} if body.blank?

      JSON.parse(body)
    rescue JSON::ParserError
      {}
    end
  end

  class << self
    # The Broadcaster base URL, from ENV with a loopback default so a co-located
    # Broadcaster needs zero configuration (mirrors PlaybackSidecar.sidecar_url).
    def broadcaster_url
      value = ENV[BROADCASTER_URL_ENV].to_s.strip
      value.presence || DEFAULT_BROADCASTER_URL
    end

    def client
      Client.new
    end
  end
end
