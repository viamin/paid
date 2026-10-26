# frozen_string_literal: true

module Tools
  class RequestLayeredVerificationAudit < BaseTool
    authorize :manage_issues?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    # @spec LAYERED-VERIFY-014
    def self.tool_name = "request_layered_verification_audit"
    def self.write_operation? = true
    def self.mcp_available? = true
    def self.description = "Preview and dispatch a bounded, issue-less verification audit. It records evidence and findings only; it never starts repair. Requires confirmation."

    def self.available_to?(user:)
      projects_for(user).any? { |project| FeatureFlags.enabled?(:layered_verification_add_on, project:) && policy_allows?(user:, record: project, query: :manage_issues?, policy_class: ProjectPolicy) }
    end

    def self.available_for_chat?(user:, session:)
      project = session&.project
      project.present? && FeatureFlags.enabled?(:layered_verification_add_on, project:) && policy_allows?(user:, record: project, query: :manage_issues?, policy_class: ProjectPolicy)
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          project_id: { type: "integer" }, obligation_ids: { type: "array", items: { type: "integer" } },
          sources: { type: "array", items: { type: "string" } }, target_revision: { type: "string" },
          budget: { type: "object" }, confirmed: { type: "boolean" }
        }, required: %w[project_id obligation_ids sources target_revision budget confirmed]
      }
    end

    # @spec LAYERED-VERIFY-010 @spec LAYERED-VERIFY-013
    def perform(project_id:, obligation_ids:, sources:, target_revision:, budget:, confirmed: false)
      raise ArgumentError, "Confirmation required: set confirmed=true to request a layered-verification audit" unless confirmed

      project = project_for(project_id)
      LayeredVerification::AuditAccess.authorize!(user: current_user, project:)
      run = LayeredVerification::Audits::Request.call(
        project:, user: current_user, obligations: project.layered_verification_obligations.where(id: obligation_ids).to_a,
        sources:, target_revision:, budget:
      )
      { id: run.id, status: run.status, goal: run.goal, issue_id: run.issue_id, project_id: run.project_id, preview: run.external_metadata }
    end

    private

    def self.projects_for(user) = Pundit.policy_scope!(user, Project)
    def project_for(id) = policy_scope(Project).find(id)
  end
end
