# frozen_string_literal: true

module Tools
  # @spec LAYERED-VERIFY-014
  class RequestLayeredVerificationAudit < BaseTool
    authorize :manage_issues?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    def self.tool_name = "request_layered_verification_audit"
    def self.write_operation? = true

    def self.description
      "Show and dispatch one bounded, report-only layered-verification audit. It never authorizes a repair. Requires explicit confirmation."
    end

    def self.available_to?(user:)
      run_agent_available_to?(user:)
    end

    def self.available_for_chat?(user:, session:)
      return false unless available_to?(user:)

      session.respond_to?(:project) && session.project.present?
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          project_id: { type: "integer", description: "The project to audit" },
          obligation_ids: { type: "array", items: { type: "integer" }, description: "Bounded obligation scope" },
          target_revision: { type: "string", description: "Repository revision to audit" },
          budget_tokens: { type: "integer", description: "Maximum token budget for this audit" },
          confirmed: { type: "boolean", description: "Must be true to dispatch the audit" }
        },
        required: %w[project_id obligation_ids target_revision budget_tokens confirmed]
      }
    end

    def perform(project_id:, obligation_ids:, target_revision:, budget_tokens:, confirmed: false)
      raise ArgumentError, "Confirmation required: set confirmed=true to request a layered-verification audit" unless confirmed

      project = project_for(project_id)
      run = LayeredVerification::Audits::Request.call(
        project:, user: current_user, obligation_ids:, target_revision:, budget_tokens:
      )
      { id: run.id, project_id: run.project_id, goal: run.goal, status: run.status,
        request: run.external_metadata.fetch("layered_verification", {}) }
    end

    private

    def project_for(id) = policy_scope(Project).find(id)
  end
end
