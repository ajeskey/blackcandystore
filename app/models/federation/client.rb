# frozen_string_literal: true

require "httparty"

module Federation
  # Federation::Client centralizes every cross-server (federation) HTTP call a
  # redeeming Server makes against a hosting Server. It lives on the redeeming
  # side and is driven by a Library_Connection's stored `server_base_url` and
  # `grant_token`.
  #
  # All requests:
  #   - target the hosting Server's `/federation` namespace under its base URL,
  #   - present the grant token as `Authorization: Bearer <grant_token>`,
  #   - set explicit `open_timeout`/`read_timeout` values so a slow or dead
  #     hosting Server can never hang a request indefinitely.
  #
  # Two timeout budgets are used, matching the design's Cross-Server HTTP API
  # Contract:
  #   - GRANT_TIMEOUT (30s) for redemption / grant confirmation (Req 5.2, 5.7),
  #   - CONTENT_TIMEOUT (10s) for content browse / stream / asset (Req 6.3).
  #
  # Network and HTTP failures are translated into domain exceptions so callers
  # (redemption in task 11.1, the stream proxy in task 15.2) can distinguish an
  # unreachable Server (Req 5.7, 6.3) from a timeout (Req 5.7, 6.3) from an
  # authorization rejection (Req 6.7) without knowing anything about HTTParty or
  # Net::HTTP internals.
  class Client
    # Base class for every federation client failure. Callers can rescue this
    # to handle any federation problem uniformly.
    class Error < StandardError; end

    # The hosting Server could not be reached at all (DNS failure, connection
    # refused, reset, TLS failure). The Library_Connection is retained unchanged
    # (Req 5.7, 6.3).
    class Unreachable < Error; end

    # The hosting Server did not respond within the allotted timeout budget
    # (Req 5.2/5.7 for grant confirmation, Req 6.3 for content).
    class Timeout < Error; end

    # The hosting Server rejected the presented grant token with an
    # authorization error (HTTP 401/403), e.g. the grant was revoked or expired
    # mid-use (Req 6.5, 6.7).
    class Unauthorized < Error; end

    # Timeout budget (in seconds) for redemption / grant confirmation calls.
    # The issuing Server must confirm within 30 seconds or the redemption is
    # rejected as unavailable (Req 5.2, 5.7).
    GRANT_TIMEOUT = 30

    # Timeout budget (in seconds) for content calls (browse, stream, asset).
    # A hosting Server that does not respond within 10 seconds is treated as
    # unavailable for content (Req 6.3).
    CONTENT_TIMEOUT = 10

    # The federation namespace all endpoints live under.
    NAMESPACE = "/federation"

    attr_reader :base_url, :grant_token

    # @param base_url [String] the hosting Server's public base URL
    #   (e.g. "https://host.example.com"), from the Library_Connection
    # @param grant_token [String] the plaintext grant token presented as the
    #   Bearer credential on every request
    def initialize(base_url:, grant_token:)
      @base_url = base_url.to_s.chomp("/")
      @grant_token = grant_token
    end

    # Confirm at redemption time that the grant is valid and references the
    # given library on the hosting Server (Req 5.2). Uses the 30s grant budget
    # so an unreachable or slow issuing Server surfaces as Unreachable/Timeout,
    # which the caller maps to a "server unavailable" redemption error (Req 5.7).
    #
    # Optionally registers the redeemer's best-effort Catalog_Nudge callback so
    # the host can POST a nudge when the shared library's catalog changes
    # (Req 6.1). Both `nudge_callback_url` and `nudge_token` are optional to keep
    # backward compatibility: when omitted they are simply not sent and the host
    # stores nothing, leaving the redeemer to rely on its scheduled pull.
    #
    # @param library_id [Integer, String] the hosting Server's library id
    # @param nudge_callback_url [String, nil] the redeemer's Nudge_Endpoint URL
    # @param nudge_token [String, nil] the opaque per-connection nudge token
    # @return [Hash] the parsed confirmation body, e.g.
    #   `{ "library" => {...}, "valid" => true }`
    def confirm_grant(library_id, nudge_callback_url: nil, nudge_token: nil)
      body = {library_id: library_id}
      body[:nudge_callback_url] = nudge_callback_url if nudge_callback_url.present?
      body[:nudge_token] = nudge_token if nudge_token.present?

      response = request(
        :post,
        "#{NAMESPACE}/grants/confirm",
        timeout: GRANT_TIMEOUT,
        body: body
      )

      parse_json(response)
    end

    # Liveness probe used to check reachability within a timeout budget. Returns
    # true on a successful response; raises Unreachable/Timeout/Unauthorized
    # otherwise so callers can decide how to react.
    #
    # @param timeout [Integer] seconds to allow (defaults to the content budget)
    # @return [Boolean] true when the hosting Server answered successfully
    def ping(timeout: CONTENT_TIMEOUT)
      request(:get, "#{NAMESPACE}/ping", timeout: timeout)
      true
    end

    # Browse a remote library's content (Req 6.1). Uses the 10s content budget
    # (Req 6.3).
    #
    # @param library_id [Integer, String] the hosting Server's library id
    # @param type [String, Symbol] one of `songs`, `albums`, `artists`
    # @param params [Hash] query parameters (e.g. pagination)
    # @return [Object] the parsed JSON list
    def browse(library_id, type, params = {})
      response = request(
        :get,
        "#{NAMESPACE}/libraries/#{library_id}/#{type}",
        timeout: CONTENT_TIMEOUT,
        query: params
      )

      parse_json(response)
    end

    # Fetch a page of catalog changes after `cursor` for a remote library
    # (Req 4.2). Uses the 10s content budget (Req 10.5). Raises Unauthorized on
    # 401/403 (the teardown signal, Req 9.4), Unreachable/Timeout on transport
    # failure (the stale signal, Req 10.1).
    #
    # @param library_id [Integer, String] the hosting Server's library id
    # @param cursor [Integer] the recorded Sync_Cursor to fetch changes after
    # @param page [Integer] the page of the paginated change set (defaults to 1)
    # @return [Hash] the parsed change response, e.g.
    #   `{ "catalog_version" => 42, "full_sync_required" => false,
    #      "changes" => [...] }`
    def changes_since(library_id, cursor, page = 1)
      response = request(
        :get,
        "#{NAMESPACE}/libraries/#{library_id}/changes",
        timeout: CONTENT_TIMEOUT,
        query: {cursor: cursor, page: page}
      )

      parse_json(response)
    end

    # Stream a remote song's audio content (Req 6.2). Uses the 10s content
    # budget (Req 6.3). Returns the raw HTTParty response so the caller (the
    # stream proxy) can forward bytes and headers without buffering/parsing.
    #
    # @param library_id [Integer, String] the hosting Server's library id
    # @param song_id [Integer, String] the hosting Server's song id
    # @param headers [Hash] extra request headers to forward (e.g. Range)
    # @return [HTTParty::Response] the raw streaming response
    def stream(library_id, song_id, headers = {})
      request(
        :get,
        "#{NAMESPACE}/libraries/#{library_id}/songs/#{song_id}/stream",
        timeout: CONTENT_TIMEOUT,
        headers: headers
      )
    end

    # Fetch a remote Displayable_Asset (cover image / artist image) or its
    # metadata (Req 9.4, 9.6). Uses the 10s content budget (Req 6.3). Returns
    # the raw response so image bytes can be forwarded directly.
    #
    # @param library_id [Integer, String] the hosting Server's library id
    # @param record_type [String, Symbol] one of `albums`, `artists`
    # @param record_id [Integer, String] the hosting Server's album/artist id
    # @param variant [String, nil] optional asset variant selector
    # @return [HTTParty::Response] the raw asset response
    def asset(library_id, record_type, record_id, variant: nil)
      query = {}
      query[:variant] = variant if variant.present?

      request(
        :get,
        "#{NAMESPACE}/libraries/#{library_id}/#{record_type}/#{record_id}/asset",
        timeout: CONTENT_TIMEOUT,
        query: query
      )
    end

    private

    # Perform a single federation request, applying the Bearer credential, the
    # open/read timeouts, and translating transport and HTTP failures into the
    # domain exceptions above.
    #
    # `timeout` is applied to both `open_timeout` and `read_timeout` so neither
    # connection setup nor a stalled response can exceed the budget.
    def request(method, path, timeout:, body: nil, query: nil, headers: {})
      options = {
        headers: default_headers.merge(headers),
        open_timeout: timeout,
        read_timeout: timeout
      }
      options[:query] = query if query.present?
      options[:body] = body.to_json unless body.nil?

      response = HTTParty.public_send(method, "#{base_url}#{path}", options)

      raise_on_error_status(response)
      response
    rescue Net::OpenTimeout, Net::ReadTimeout, ::Timeout::Error => e
      raise Timeout, "hosting server did not respond within #{timeout}s: #{e.message}"
    rescue SocketError, Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH,
      Errno::ENETUNREACH, OpenSSL::SSL::SSLError, HTTParty::Error => e
      raise Unreachable, "hosting server is unreachable: #{e.message}"
    end

    # Map non-success HTTP statuses to domain exceptions. Authorization
    # rejections (401/403) become Unauthorized so a revoked/expired grant is
    # surfaced explicitly (Req 6.5, 6.7); every other non-success status becomes
    # a generic Error.
    def raise_on_error_status(response)
      code = response.code.to_i
      return if code.between?(200, 299)

      case code
      when 401, 403
        raise Unauthorized, "hosting server rejected the grant token (HTTP #{code})"
      else
        raise Error, "hosting server returned HTTP #{code}"
      end
    end

    def default_headers
      {
        "Authorization" => "Bearer #{grant_token}",
        "Accept" => "application/json"
      }
    end

    def parse_json(response)
      return nil if response.body.blank?

      JSON.parse(response.body)
    rescue JSON::ParserError => e
      raise Error, "hosting server returned an unparseable response: #{e.message}"
    end
  end
end
