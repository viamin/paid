# frozen_string_literal: true

module Previews
  # Allocates and releases tunnel ports from a bounded range (RDR-045).
  #
  # The pool tracks ports already claimed by ready/active preview sessions so
  # two concurrent previews never collide on the same localhost tunnel port.
  # Allocation is serialized with a per-project PostgreSQL advisory lock
  # around {acquire} / {release}, and the chosen port is persisted to the
  # session row inside the same lock so the partial unique index
  # `index_preview_sessions_on_tunnel_port_active` defends against any
  # application-level race we missed. Inside the lock we also null the
  # `tunnel_port` of any expired-but-not-yet-reaped session so its port is
  # free for re-allocation and the partial index treats the row as gone.
  class TunnelPortPool
    Exhausted = Class.new(StandardError)

    LOCK_NAMESPACE = 1_357_180_002

    attr_reader :range

    def initialize(range: Previews.port_range)
      @range = range
    end

    # Reserves the lowest free port for `session` and persists it on the
    # session row within a per-project advisory lock. Raises {Exhausted} if
    # every port in the range is currently held by another active session.
    def acquire(session)
      project_id = session.project_id
      with_lock(project_id) do
        clear_expired_port_claims!(project_id)
        port = next_free_port
        raise Exhausted, "No preview tunnel ports available in #{range}" if port.nil?

        session.update_column(:tunnel_port, port)
        port
      end
    end

    # Releases the port held by `session` (no-op when the session has none).
    # Same per-project advisory lock as {#acquire} so we never observe a
    # half-released state from a concurrent allocator.
    def release(session)
      return if session.tunnel_port.blank?

      with_lock(session.project_id) do
        session.update_column(:tunnel_port, nil)
      end
    end

    private

    def next_free_port
      claimed = claimed_ports
      range.find { |port| !claimed.include?(port) }
    end

    def claimed_ports
      PreviewSession.active.where.not(tunnel_port: nil).pluck(:tunnel_port)
    end

    # When a session has expired but not yet been reaped, its `tunnel_port`
    # is still set in the DB even though the {PreviewSession.active} scope
    # would skip it. Without this cleanup, the partial unique index on
    # `tunnel_port` (which only filters by status) would still treat the port
    # as taken. Null the column so the port becomes allocatable again; the
    # row is reaped to `stopped` shortly after by {Previews::Expire}.
    def clear_expired_port_claims!(project_id)
      PreviewSession
        .where(project_id: project_id, status: PreviewSession::ACTIVE_STATUSES)
        .where("expires_at <= ?", Time.current)
        .where.not(tunnel_port: nil)
        .update_all(tunnel_port: nil)
    end

    def with_lock(project_id)
      connection = ActiveRecord::Base.connection
      key = project_id % 2_147_483_647

      connection.execute("SELECT pg_advisory_lock(#{LOCK_NAMESPACE}, #{key})")
      yield
    ensure
      begin
        connection.execute("SELECT pg_advisory_unlock(#{LOCK_NAMESPACE}, #{key})")
      rescue StandardError
        # Connection may already be closed; releasing the lock is best-effort.
      end
    end
  end
end
