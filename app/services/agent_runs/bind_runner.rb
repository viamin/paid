# frozen_string_literal: true

module AgentRuns
  # Resolves and binds a runnable runner to a queued run at dequeue time.
  #
  # Implements the late-binding half of the runner-agnostic queue redesign
  # (#2563). Enqueue paths (Issues::EnqueueEligible, Issues::AutoPick, etc.)
  # now create runs with +runner_id: nil+ and an intended +agent_type+;
  # ProcessRunQueueJob calls this service just before claiming each run to
  # pick a healthy runner over the runnable set, honoring any explicit
  # preference the run carries.
  #
  # Failover policy:
  # - Auto-pick runs (default): any healthy runner matching the intended
  #   +agent_type+ is preferred; if none exists, any runnable runner is
  #   acceptable (the project just wants a PR).
  # - Manual runs that explicitly chose an agent_type: same-agent_type
  #   failover is allowed, but switching to a different agent_type leaves
  #   the run queued (do not silently switch on user-explicit intent).
  class BindRunner
    def self.call(...)
      new(...).call
    end

    def initialize(agent_run:, explicit_runner_preference: nil, logger: nil)
      @agent_run = agent_run
      @explicit_runner_preference = explicit_runner_preference
      @logger = logger
    end

    # Returns the resolved Runner, or nil when no runnable runner can serve
    # this run. When the resolver returns a different agent_type than the
    # run's intended one, the run's +agent_type+ is updated in place to
    # reflect the actual choice — but only when the resolver is allowed to
    # change it (auto-pick, or manual without an explicit agent_type).
    def call
      return nil if agent_run.runner_id.present?

      requested_runner_id, requested_agent_type = resolution_preferences

      resolved_runner_id, resolved_agent_type = AgentRuns::RunnerResolver.call(
        project: agent_run.project,
        goal: agent_run.goal,
        requested_runner_id: requested_runner_id,
        requested_agent_type: requested_agent_type,
        respect_requested: respect_explicit_request?,
        logger: logger
      )

      runner = Runner.kept_only.find_by(id: resolved_runner_id)
      return nil unless runner

      apply_resolution!(runner, resolved_agent_type)
      runner
    end

    private

    attr_reader :agent_run, :explicit_runner_preference, :logger

    # When the user explicitly pinned a specific runner (manual trigger),
    # feed its id back into the resolver so it gets first pick if still
    # runnable. For auto-pick (no explicit runner) do NOT pass the run's
    # stored agent_type as a +requested_agent_type+: the resolver's
    # +requested_selection+ short-circuits to +[nil, agent_type]+ whenever
    # the agent type is statically container-executable, which would skip
    # +project_preferred_agent_selection+ / +default_runner+ and leave the
    # run pinned to no runner at all (it stays queued forever). The
    # project's +preferred_agent_type+ is re-derived inside the resolver
    # via +project_preferred_agent_selection+, so passing +[nil, nil]+ lets
    # the real runner-selection paths run and return an actual runner id.
    def resolution_preferences
      if explicit_runner_preference.is_a?(Runner)
        [ explicit_runner_preference.id, agent_run.agent_type ]
      else
        [ nil, nil ]
      end
    end

    # The resolver should only honor an explicit +requested_*+ selection
    # when the caller actually carries one. A manual run that pinned a
    # runner passes +respect_requested: true+ so the resolver honors it;
    # auto-pick (no explicit runner) passes +false+ so the resolver uses
    # its own preference/default selection instead of short-circuiting on
    # the run's stored agent_type.
    def respect_explicit_request?
      explicit_runner_preference.is_a?(Runner)
    end

    def apply_resolution!(runner, resolved_agent_type)
      target_agent_type = resolved_agent_type.presence ||
        Runner.agent_type_for(runner.runner_key) ||
        agent_run.agent_type

      updates = { runner_id: runner.id }
      updates[:agent_type] = target_agent_type if should_update_agent_type?(target_agent_type)

      agent_run.update_columns(updates) if updates.any?
    end

    # Manual runs that explicitly chose an agent_type must keep that
    # agent_type. Auto-pick (and manual without an explicit agent_type,
    # which we model as auto-pick here) is free to accept whatever the
    # resolver returned.
    def should_update_agent_type?(target_agent_type)
      return true if target_agent_type == agent_run.agent_type
      return false if manual_explicit_agent_type?

      true
    end

    def manual_explicit_agent_type?
      agent_run.manual? && explicit_runner_preference.is_a?(Runner)
    end
  end
end
