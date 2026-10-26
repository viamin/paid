# frozen_string_literal: true

module Tools
  class RequestLayeredVerificationAudit < BaseTool
    authorize :manage_issues?, ->(args) { project_for(args.fetch(:project_id)) }, policy_class: ProjectPolicy

    def self.tool_name = "request_layered_verification_audit"
    def self.write_operation? = true
    def self.confirmation_mode = :post_dispatch
    def self.mcp_available? = true
    def self.description = "Prepare a bounded, issue-less layered-verification audit. It records evidence and findings only; it never repairs repository artifacts."

    def self.available_to?(user:)
      return false if user.blank?

      Pundit.policy_scope!(user, Project).any? { |project| FeatureFlags.enabled?(:layered_verification_add_on, project:) && policy_allows?(user:, record: project, query: :manage_issues?, policy_class: ProjectPolicy) }
    end

    def self.available_for_chat?(user:, session:)
      project = session&.project
      project.present? && FeatureFlags.enabled?(:layered_verification_add_on, project:) &&
        policy_allows?(user:, record: project, query: :manage_issues?, policy_class: ProjectPolicy)
    end

    def self.input_schema
      { type: "object", properties: {
        project_id: { type: "integer" }, obligation_ids: { type: "array", items: { type: "integer" } },
        source_references: { type: "array", items: { type: "string" } }, target_revision: { type: "string" },
        budget_tokens: { type: "integer" }
      }, required: %w[project_id obligation_ids source_references target_revision budget_tokens] }
    end

    def perform(project_id:, obligation_ids:, source_references:, target_revision:, budget_tokens:)
      project = project_for(project_id)
      LayeredVerification::Audits::Request.preview(project:, obligation_ids:, source_references:, target_revision:, budget_tokens:)
    end

    def resolve_confirmation(decision:, pending_result:)
      raise ArgumentError, "decision must be approve or deny" unless decision.in?(%i[approve deny])
      return { status: "cancelled" } if decision == :deny

      data = pending_result.stringify_keys
      project = project_for(data.fetch("project_id"))
      run = LayeredVerification::Audits::Request.call(user: current_user, project:,
        obligation_ids: data.fetch("obligation_ids"), source_references: data.fetch("source_references"),
        target_revision: data.fetch("target_revision"), budget_tokens: data.fetch("budget_tokens"))
      { id: run.id, status: run.status, goal: run.goal, resolved_scope: run.external_metadata }
    end

    private

    def project_for(id) = policy_scope(Project).find(id)
  end
end
