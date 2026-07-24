# frozen_string_literal: true

module AgentRuns
  # Resolves and binds a runnable runner to a queued run at dequeue time.
  #
  # Implements the late-binding half of the runner-agnostic queue redesign
  # (#2563). Enqueue paths (Issues::AutoPick, Issues::EnqueueEligible, etc.)
  # create runs with +runner_id: nil+ and an intended +agent_type+;
  # ProcessRunQueueJob calls this service just before claiming each run to
  # pick a healthy runner over the runnable set.
  #
  # This service only ever handles runner-agnostic (auto-pick) queued runs.
  # Manual and resume runs are created with their runner already pinned
  # (Projects::AgentRunsController#create_agent_run), so they reach
  # ProcessRunQueueJob already bound (+runner_id.present?+) and never flow
  # through here on the first dispatch. When such a pinned runner is
  # unavailable (rate-limited, circuit-open), ProcessRunQueueJob clears the
  # pin and re-invokes this service to fall back to a healthy alternative —
  # weighting/preference is a soft preference and never blocks work.
  #
  # Failover policy: any healthy runner is acceptable (the project just wants
  # the work done), so +agent_type+ is updated to whatever the resolver returns,
  # including a different agent family. The +exclude_runner_ids+ set (runners
  # that already failed preflight during the current dequeue pass) is threaded
  # into the resolver so the run is never pinned back to a runner known-unhealthy
  # this pass — it falls through to a healthy alternative instead.
  class BindRunner
    def self.call(...)
      new(...).call
    end

    def initialize(agent_run:, exclude_runner_ids: [], logger: nil)
      @agent_run = agent_run
      @exclude_runner_ids = Array(exclude_runner_ids)
      @logger = logger
    end

    # Returns the resolved Runner, or nil when no runnable runner can serve
    # this run. The run's +agent_type+ is updated in place to the agent type
    # of the resolved runner (auto-pick accepts any healthy runner).
    def call
      return nil if agent_run.runner_id.present?

      resolved_runner_id, resolved_agent_type = AgentRuns::RunnerResolver.call(
        project: agent_run.project,
        goal: agent_run.goal,
        exclude_runner_ids: exclude_runner_ids,
        effective_runner: agent_run.effective_runner,
        logger: logger
      )

      runner = Runner.kept_only.find_by(id: resolved_runner_id)
      return nil unless runner

      apply_resolution!(runner, resolved_agent_type)
      runner
    end

    private

    attr_reader :agent_run, :exclude_runner_ids, :logger

    def apply_resolution!(runner, resolved_agent_type)
      target_agent_type = resolved_agent_type.presence ||
        Runner.agent_type_for(runner.runner_key) ||
        agent_run.agent_type

      updates = { runner_id: runner.id }
      updates[:agent_type] = target_agent_type unless target_agent_type == agent_run.agent_type

      agent_run.update_columns(updates) if updates.any?
    end
  end
end
