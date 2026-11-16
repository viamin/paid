# frozen_string_literal: true

module MaintenanceRuns
  # Shared admission boundary for manual maintenance runs (RDR-075 M01).
  # The UI controller and the MCP tool both start runs through this service so
  # the `maintenance_runs` rollout guard, the objective admission rule, and the
  # start-time context snapshot are identical on every surface.
  # @spec MAINT-002 @spec MAINT-010 @spec MAINT-011 @spec MAINT-015
  class Start
    class FeatureDisabledError < StandardError; end
    class MissingObjectiveError < StandardError; end
    class UnknownObjectiveError < StandardError; end
    class BudgetExceededError < StandardError; end
    class NoRunnableRunnerError < StandardError; end
    class RevisionUnavailableError < StandardError; end

    def self.call(...)
      new(...).call
    end

    def initialize(project:, actor:, objective: nil, guidance: nil, scope: nil)
      @project = project
      @actor = actor
      @objective = objective.to_s.presence
      @guidance = guidance.to_s.strip
      @scope = scope.to_s.strip.presence
    end

    def call
      ensure_feature_enabled!
      ensure_objective!
      ensure_budget!

      runner_id, agent_type = AgentRuns::RunnerResolver.call(project: project, goal: AgentRun::MAINTENANCE_GOAL)
      raise NoRunnableRunnerError, "No runnable runner could be resolved for this project." if agent_type.blank?

      run = AgentRun.create!(
        project: project,
        issue: nil,
        initiating_user: actor,
        runner_id: runner_id,
        agent_type: agent_type,
        goal: AgentRun::MAINTENANCE_GOAL,
        custom_prompt: BuildPrompt.call(objective: objective, guidance: guidance, scope: scope),
        trigger_type: "manual",
        status: "queued",
        maintenance_objective: objective,
        maintenance_recipe_version: resolved_recipe&.version,
        maintenance_scope: scope,
        maintenance_scope_kind: scope.present? ? "named" : "broad",
        maintenance_guidance: guidance.presence,
        maintenance_pinned_revision: pinned_revision,
        maintenance_limits: limits_snapshot
      )
      ProcessRunQueueJob.perform_later
      run
    end

    private

    attr_reader :project, :actor, :objective, :guidance, :scope

    # @spec MAINT-002 — every surface refuses admission identically while the
    # guard is off for the project's tenant.
    def ensure_feature_enabled!
      return if FeatureFlags.enabled?(:maintenance_runs, project: project)

      raise FeatureDisabledError,
            "Maintenance runs are not enabled for this project's tenant (maintenance_runs feature flag)."
    end

    # @spec MAINT-011 — a recipe objective or nonblank free-text guidance is
    # required; scope alone is not an investigation objective.
    def ensure_objective!
      raise MissingObjectiveError, "Provide a recipe objective or nonblank guidance to start a maintenance run." if objective.blank? && guidance.blank?

      return if objective.blank?
      return if Recipes.exists?(objective)

      raise UnknownObjectiveError,
            "Unknown maintenance objective: #{objective}. Available objectives: #{Recipes.keys.join(", ")}."
    end

    def ensure_budget!
      return if CostBudgets::Check.call(project)[:allowed]

      raise BudgetExceededError,
            "Your project's AI budget has been reached. Please adjust your budget settings or try again later."
    end

    def resolved_recipe
      return @resolved_recipe if defined?(@resolved_recipe)

      @resolved_recipe = objective.present? ? Recipes.fetch(objective) : nil
    end

    # Resolve the mutable default branch once at admission. The resulting SHA
    # is immutable context for this run and any retry of it.
    # @spec MAINT-015
    def pinned_revision
      ref = project.client.ref(project.full_name, "heads/#{project.default_branch.presence || "main"}")
      revision = ref&.object&.sha.to_s
      return revision if revision.match?(/\A[0-9a-f]{40,64}\z/i)

      raise RevisionUnavailableError, "Could not resolve the project's default branch commit SHA."
    end

    # Effective execution-limit snapshot consistent with the existing run
    # budget fields the workflow already enforces (MAINT-015).
    def limits_snapshot
      { "max_execution_seconds" => project.max_execution_seconds }
    end
  end
end
