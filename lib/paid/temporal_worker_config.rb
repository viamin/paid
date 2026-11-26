# frozen_string_literal: true

module Paid
  module TemporalWorkerConfig # @spec TEMPORAL-ORCHESTRATION-002
    VALID_MODES = %w[poll agent both].freeze

    module_function

    def worker_mode(env = ENV)
      validate_worker_mode!(env.fetch("TEMPORAL_WORKER_MODE", "both"))
    end

    # @spec OBSERVABILITY-006
    def launch_mode(arguments, env = ENV)
      return worker_mode(env) if arguments.empty?

      unless arguments.one? && arguments.first.start_with?("--mode=")
        raise ArgumentError, "Expected one --mode=poll|agent|both argument"
      end

      mode = validate_worker_mode!(arguments.first.delete_prefix("--mode="))
      if env.key?("TEMPORAL_WORKER_MODE") && env.fetch("TEMPORAL_WORKER_MODE") != mode
        raise ArgumentError, "Worker mode argument conflicts with TEMPORAL_WORKER_MODE"
      end

      mode
    end

    # Make the effective CLI/default mode available to readiness publishing.
    # @spec DEVELOPMENT-ENVIRONMENT-UPDATE-006
    def bind_launch_mode!(arguments, env = ENV)
      launch_mode(arguments, env).tap { |mode| env["TEMPORAL_WORKER_MODE"] = mode }
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

    # Long-running regular activities on both queues use BaseActivity's
    # periodic-heartbeat helper, which runs the activity body in a worker
    # thread so the activity thread can keep heartbeating. Once that worker
    # thread touches Active Record it can hold a second DB connection
    # concurrently with the activity slot, so budget one extra connection per
    # regular activity slot on each selected worker set. Local activities are
    # not included here because they do not currently use the helper.
    def heartbeat_thread_connections(worker_mode:, agent_activity_slots:, poll_activity_slots:)
      case validate_worker_mode!(worker_mode)
      when "poll"
        poll_activity_slots
      when "agent"
        agent_activity_slots
      when "both"
        agent_activity_slots + poll_activity_slots
      end
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
        heartbeat_thread_connections(
          worker_mode: worker_mode,
          agent_activity_slots: agent_activity_slots,
          poll_activity_slots: poll_activity_slots
        ) +
        selected_pool_overhead(worker_mode: worker_mode)
    end
  end
end
