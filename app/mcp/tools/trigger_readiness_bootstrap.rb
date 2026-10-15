# frozen_string_literal: true

module Tools
  # @spec PROJECT-READINESS-007
  class TriggerReadinessBootstrap < BaseTool
    authorize :run_agent?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    def self.tool_name = "trigger_readiness_bootstrap"
    def self.write_operation? = true
    def self.description
      "Start one readiness-bootstrap run for a project currently awaiting setup. " \
        "Requires explicit confirmation."
    end
    def self.available_to?(user:) = run_agent_available_to?(user:)

    def self.input_schema
      {
        type: "object",
        properties: {
          project_id: { type: "integer", description: "The project ID" },
          confirmed: { type: "boolean", description: "Must be true to execute this write operation" }
        },
        required: %w[project_id confirmed]
      }
    end

    def perform(project_id:, confirmed: false)
      raise ArgumentError, "Confirmation required: set confirmed=true to trigger readiness bootstrap" unless confirmed

      run = Projects::Readiness::Bootstrap.call(project: project_for(project_id), user: current_user)
      { id: run.id, project_id: run.project_id, goal: run.goal, status: run.status, created_at: run.created_at }
    rescue Projects::Readiness::Bootstrap::NotReadyError,
           Projects::Readiness::Bootstrap::ActiveRunError,
           Projects::Readiness::Bootstrap::BudgetExceededError,
           Projects::Readiness::Bootstrap::NoRunnableRunnerError => error
      raise ArgumentError, error.message
    end

    private

    def project_for(id) = policy_scope(Project).find(id)
  end
end
