# frozen_string_literal: true

module Previews
  # Allocates and releases tunnel ports from a bounded range (RDR-045).
  #
  # The pool tracks ports already claimed by ready/active preview sessions so
  # two concurrent previews never collide on the same localhost tunnel port.
  # Allocation is serialized with a single PostgreSQL advisory lock protecting
  # the global port pool
  # around {acquire} / {release}, and the chosen port is persisted to the
  # session row inside the same lock so the partial unique index
  # `index_preview_sessions_on_tunnel_port_active` defends against any
  # application-level race we missed.
  class TunnelPortPool
    Exhausted = Class.new(StandardError)

    LOCK_NAMESPACE = 1_357_180_002

    attr_reader :range

    def initialize(range: Previews.port_range)
      @range = range
    end

    # Reserves the lowest free port for `session` and persists it on the
    # session row within a global advisory lock. Raises {Exhausted} if
    # every port in the range is currently held by another active session.
    def acquire(session)
      with_lock do
        TenantContext.with_system_access do
          release_expired_claims!
          port = next_free_port
          raise Exhausted, "No preview tunnel ports available in #{range}" if port.nil?

          session.update_column(:tunnel_port, port)
          port
        end
      end
    end

    # Releases the port held by `session` (no-op when the session has none).
    # Same global advisory lock as {#acquire} so we never observe a
    # half-released state from a concurrent allocator.
    def release(session)
      return if session.tunnel_port.blank?

      with_lock do
        TenantContext.with_system_access do
          session.update_column(:tunnel_port, nil)
        end
      end
    end

    private

    def next_free_port
      claimed = claimed_ports
      range.find { |port| !claimed.include?(port) }
    end

    def release_expired_claims!
      PreviewSession
        .expiring_before(Time.current)
        .where.not(tunnel_port: nil)
        .update_all(tunnel_port: nil)
    end

    def claimed_ports
      PreviewSession
        .active
        .where.not(tunnel_port: nil)
        .pluck(:tunnel_port)
    end

    def with_lock
      connection = ActiveRecord::Base.connection

      connection.execute("SELECT pg_advisory_lock(#{LOCK_NAMESPACE})")
      yield
    ensure
      begin
        connection.execute("SELECT pg_advisory_unlock(#{LOCK_NAMESPACE})")
      rescue StandardError
        # Connection may already be closed; releasing the lock is best-effort.
      end
    end
  end
end
