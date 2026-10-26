# frozen_string_literal: true

module Tools
  class RequestLayeredVerificationAudit < BaseTool
    # @spec LAYERED-VERIFY-010 @spec LAYERED-VERIFY-014
    authorize :manage_issues?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    def self.tool_name = "request_layered_verification_audit"
    def self.write_operation? = true
    def self.description
      "Preview and queue a bounded, issue-less layered-verification audit. It records reports and findings only; it never repairs code or intent. Requires confirmation."
    end

    def self.available_to?(user:) = run_agent_available_to?(user:)
    def self.available_for_chat?(user:, session:) = session&.project.present? && available_to?(user:)

    def self.input_schema
      {
        type: "object",
        properties: {
          project_id: { type: "integer" },
          obligation_ids: { type: "array", items: { type: "integer" }, description: "Resolved obligations to audit" },
          source_references: { type: "array", items: { type: "string" }, description: "Business and engineering source passages" },
          target_revision: { type: "string", description: "Pinned repository revision" },
          budget_tokens: { type: "integer", description: "Maximum token budget for this audit" },
          confirmed: { type: "boolean" }
        },
        required: %w[project_id obligation_ids source_references target_revision budget_tokens confirmed]
      }
    end

    def perform(project_id:, obligation_ids:, source_references:, target_revision:, budget_tokens:, confirmed: false)
      raise ArgumentError, "Confirmation required: set confirmed=true to request a layered-verification audit" unless confirmed

      project = project_for(project_id)
      run = LayeredVerification::Audits::Request.call(
        user: current_user,
        project:,
        obligation_ids:,
        source_references:,
        target_revision:,
        budget_tokens:
      )

      { id: run.id, status: run.status, goal: run.goal, project_id: run.project_id, dispatch: run.external_metadata.fetch("layered_verification_audit") }
    rescue LayeredVerification::AuditAccess::FeatureDisabledError, LayeredVerification::AuditAccess::UnauthorizedError => error
      raise Pundit::NotAuthorizedError, error.message
    end

    private

    def project_for(id) = policy_scope(Project).find(id)
  end
end
