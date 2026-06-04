# frozen_string_literal: true

module Paid
  module TemporalWorkerConfig
    VALID_MODES = %w[poll agent both].freeze

    module_function

    def worker_mode(env = ENV)
      validate_worker_mode!(env.fetch("TEMPORAL_WORKER_MODE", "both"))
    end

    def validate_worker_mode!(worker_mode)
      return worker_mode if VALID_MODES.include?(worker_mode)

      raise ArgumentError,
            "Invalid TEMPORAL_WORKER_MODE=#{worker_mode.inspect}; expected 'poll', 'agent', or 'both'"
    end

    def selected_activity_slots(worker_mode:, agent_activity_slots:, agent_local_activity_slots:,
                                poll_activity_slots:, poll_local_activity_slots:)
      case validate_worker_mode!(worker_mode)
      when "poll"
        poll_activity_slots + poll_local_activity_slots
      when "agent"
        agent_activity_slots + agent_local_activity_slots
      when "both"
        agent_activity_slots + agent_local_activity_slots +
          poll_activity_slots + poll_local_activity_slots
      end
    end

    def selected_pool_overhead(worker_mode:)
      validate_worker_mode!(worker_mode) == "both" ? 4 : 2
    end

    # RunAgentActivity (a regular agent-queue activity) spawns a heartbeat
    # worker thread that holds its own DB connection for the entire run —
    # it streams agent output to the DB on every chunk, so the connection
    # cannot be released mid-run without thrashing the pool or losing the
    # per-connection tenant RLS context. That worker thread runs concurrently
    # with the activity's main thread, so each agent activity slot consumes
    # two connections, not one. Local/poll activities do not spawn this
    # thread. Only the agent (non-local) pool is affected.
    def agent_heartbeat_connections(worker_mode:, agent_activity_slots:)
      %w[agent both].include?(validate_worker_mode!(worker_mode)) ? agent_activity_slots : 0
    end

    def min_required_db_pool(worker_mode:, agent_activity_slots:, agent_local_activity_slots:,
                             poll_activity_slots:, poll_local_activity_slots:)
      selected_activity_slots(
        worker_mode: worker_mode,
        agent_activity_slots: agent_activity_slots,
        agent_local_activity_slots: agent_local_activity_slots,
        poll_activity_slots: poll_activity_slots,
        poll_local_activity_slots: poll_local_activity_slots
      ) +
        agent_heartbeat_connections(worker_mode: worker_mode, agent_activity_slots: agent_activity_slots) +
        selected_pool_overhead(worker_mode: worker_mode)
    end
  end
end
