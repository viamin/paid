# frozen_string_literal: true

module Tools
  class RequestLayeredVerificationAudit < BaseTool
    # @spec LAYERED-VERIFY-014
    authorize :manage_issues?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    def self.tool_name = "request_layered_verification_audit"
    def self.write_operation? = true
    def self.description = "Request a bounded, report-only layered-verification audit. Requires confirmation."

    def self.available_to?(user:)
      user.present? && Pundit.policy_scope!(user, Project).any? { |project|
        FeatureFlags.enabled?(:layered_verification_add_on, project:) && policy_allows?(user:, record: project, query: :manage_issues?, policy_class: ProjectPolicy)
      }
    rescue Pundit::NotAuthorizedError
      false
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          project_id: { type: "integer" }, obligation_ids: { type: "array", items: { type: "integer" } },
          source_references: { type: "array", items: { type: "string" } }, target_revision: { type: "string" },
          budget: { type: "object" }, plan: { type: "object" }, confirmed: { type: "boolean" }
        }, required: %w[project_id source_references target_revision budget plan confirmed]
      }
    end

    def perform(project_id:, source_references:, target_revision:, budget:, plan:, confirmed: false, obligation_ids: nil)
      raise ArgumentError, "Confirmation required: set confirmed=true to request a layered-verification audit" unless confirmed

      run = LayeredVerification::Audits::Request.call(
        project: project_for(project_id), user: current_user, obligation_ids:, source_references:, target_revision:, budget:, plan:
      )
      { id: run.id, status: run.status, goal: run.goal, project_id: run.project_id, issue_id: run.issue_id }
    end

    private

    def project_for(id) = policy_scope(Project).find(id)
  end
end
