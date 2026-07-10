# frozen_string_literal: true

module Previews
  # Allocates and releases tunnel ports from a bounded range (RDR-045).
  #
  # The pool tracks ports already claimed by ready/active preview sessions so
  # two concurrent previews never collide on the same localhost tunnel port.
  # Port allocation is intentionally in-process: the preview provisioning
  # service holds a short-lived transaction around allocate/release.
  class TunnelPortPool
    Exhausted = Class.new(StandardError)

    attr_reader :range

    def initialize(range: Previews.port_range)
      @range = range
    end

    def acquire
      available = range.to_a - claimed_ports
      raise Exhausted, "No preview tunnel ports available in #{range}" if available.empty?

      available.min
    end

    def release(port)
      return if port.blank?

      # No external reservation to clear — ports are claimed implicitly by the
      # tunnel_port column on active sessions, so release is a no-op here. The
      # provisioning service clears the column when stopping a session.
    end

    private

    def claimed_ports
      PreviewSession.active.where.not(tunnel_port: nil).pluck(:tunnel_port)
    end
  end
end
