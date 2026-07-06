# frozen_string_literal: true

# FakeBroadcaster is an in-memory stand-in for Broadcaster::Client used by tests
# that exercise the lifecycle services / ResumeStreamsJob without a real
# out-of-process Broadcaster (task 9.3 wiring). It mirrors the control-client
# surface (`start_broadcast`, `stop_broadcast`, `next_source`, `status`),
# records every call for assertions, and returns a trivial acknowledgement.
#
# Pass `available: false` to simulate an unreachable Broadcaster so a test can
# assert the domain-error translation (Broadcaster::Unavailable) and the
# resulting lifecycle behavior.
class FakeBroadcaster
  attr_reader :started, :stopped, :advanced

  def initialize(available: true)
    @available = available
    @started = []
    @stopped = []
    @advanced = []
  end

  def start_broadcast(broadcast_id:, kind: nil, source: nil)
    raise Broadcaster::Unavailable, "fake broadcaster is unavailable" unless @available

    @started << { broadcast_id: broadcast_id, kind: kind, source: source }
    { "handle" => broadcast_id }
  end

  def stop_broadcast(broadcast_id)
    raise Broadcaster::Unavailable, "fake broadcaster is unavailable" unless @available

    @stopped << broadcast_id
    {}
  end

  def next_source(broadcast_id, source:)
    raise Broadcaster::Unavailable, "fake broadcaster is unavailable" unless @available

    @advanced << { broadcast_id: broadcast_id, source: source }
    {}
  end

  def status(broadcast_id)
    raise Broadcaster::Unavailable, "fake broadcaster is unavailable" unless @available

    { "broadcast_id" => broadcast_id, "position" => 0, "listeners" => 0, "uptime" => 0 }
  end
end
