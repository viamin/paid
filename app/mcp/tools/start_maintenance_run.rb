# frozen_string_literal: true

module Tools
  class StartMaintenanceRun < BaseTool
    authorize :run_agent?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    def self.tool_name = "start_maintenance_run"
    def self.write_operation? = true
    def self.mcp_available? = true

    def self.description
      "Start a report-only maintenance run on a project without an issue or pull request. " \
        "Pass a recipe objective, free-text guidance, or both; optional scope names paths, symbols, or " \
        "a free-form target. The scan never changes source files. Requires explicit confirmation."
    end

    def self.available_to?(user:)
      maintenance_runs_available_to?(user:)
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          project_id: { type: "integer", description: "The project ID" },
          objective: { type: "string", description: "Optional recipe objective key", enum: MaintenanceRuns::Recipes.keys },
          type: { type: "string", maxLength: 100, description: "Optional curated optimization type. Unmapped values become a retained custom objective.", enum: MaintenanceRuns::OptimizationTypes.keys },
          guidance: { type: "string", description: "Free-text maintenance question or instructions. Required unless an optimization type or recipe objective is selected; captured verbatim." },
          scope: { type: "string", description: "Optional scope: paths, symbols, or a free-form target. Ambiguous or missing named targets produce a clarification outcome instead of a whole-repository scan." },
          confirmed: { type: "boolean", description: "Must be true to execute this write operation" }
        },
        required: %w[project_id confirmed]
      }
    end

    # @spec MAINT-002 — the MCP surface refuses admission identically while
    # the guard is off; MaintenanceRuns::Start owns the shared gate.
    # @spec MAINT-010 @spec MAINT-011 MAINT-OPT-004 MAINT-OPT-005 MAINT-OPT-006
    def perform(project_id:, confirmed: false, objective: nil, type: nil, guidance: nil, scope: nil)
      raise ArgumentError, "Confirmation required: set confirmed=true to start a maintenance run" unless confirmed

      project = project_for(project_id)
      run = MaintenanceRuns::Start.call(
        project: project,
        actor: current_user,
        objective: objective,
        type: type,
        guidance: guidance,
        scope: scope
      )

      {
        id: run.id,
        status: run.status,
        goal: run.goal,
        project_id: run.project_id,
        issue_id: nil,
        type: run.maintenance_type,
        scope_kind: run.maintenance_scope_kind,
        created_at: run.created_at
      }
    end

    private

    def project_for(project_id)
      @projects_by_id ||= {}
      @projects_by_id[project_id] ||= policy_scope(Project).find(project_id)
    end

    # The tool is only advertised to agent loops while the rollout guard is
    # enabled for at least one project the user can act on.
    def self.maintenance_runs_available_to?(user:)
      return false if user.blank?

      Pundit.policy_scope!(user, Project).any? do |project|
        FeatureFlags.enabled?(:maintenance_runs, project: project) &&
          policy_allows?(user:, record: project, query: :run_agent?, policy_class: ProjectPolicy)
      end
    rescue Pundit::NotAuthorizedError
      false
    end
  end
end
